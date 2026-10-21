# syntax=docker/dockerfile:1
# =============================================================================
# QGIS Server + Varnish i en och samma avbild.
#
#   klient --> Varnish (port 8080, cache) --> QGIS Server (127.0.0.1:8081, bara inuti containern)
#
# Bygg:  docker build -t qgis-varnish .
# Se README.md för hur man kör och testar.
#
# Avbilden byggs i två steg. Steg "build" installerar Varnish och städar bort filer som
# inte behövs. Slutsteget kopierar sedan hela filsystemet till ETT lager, eftersom filer som
# tas bort i ett senare lager annars ändå ligger kvar i basavbildens lager.
# =============================================================================
ARG QGIS_SERVER_VERSION=3.44.14
FROM 3liz/qgis-map-server:${QGIS_SERVER_VERSION} AS build

# --- Installera Varnish -------------------------------------------------------
# gettext-base: ger kommandot envsubst (fyller i miljövariabler i VCL-mallen)
# curl:         används för att vänta in QGIS Server och för healthcheck
RUN apt-get update \
    && apt-get install -y --no-install-recommends varnish gettext-base curl \
    && rm -rf /var/lib/apt/lists/*

# --- Filer ------------------------------------------------------------------
COPY default.vcl.template /etc/varnish/default.vcl.template
# Licenstexten för filerna i det här repot (BSD-2-Clause kräver att den följer med i binär form).
COPY LICENSE /usr/share/doc/qgis-varnish/LICENSE
COPY start.sh /usr/local/bin/start.sh
# Tar bort ev. Windows-radslut (CRLF) så att skripten fungerar även om filerna
# checkats ut på Windows, och gör startskriptet körbart.
RUN sed -i 's/\r$//' /usr/local/bin/start.sh /etc/varnish/default.vcl.template \
    && chmod 755 /usr/local/bin/start.sh

# --- Städa --------------------------------------------------------------------
# Dokumentation (utom licenstexterna), testkataloger i Python-paketen, sanitizer-bibliotek
# (används bara med -fsanitize) och cacher. gcc:s lto1 måste vara kvar: länkningen av VCL kör den.
RUN find /usr/share/doc ! -xtype d ! -name copyright ! -path /usr/share/doc/qgis-varnish/LICENSE -delete \
    && find /usr/share/doc -xdev -type d -empty -delete \
    && find /usr/lib/python3/dist-packages /opt/local -type d \( -name tests -o -name test \) -prune -exec rm -rf {} + \
    && find /usr/lib/x86_64-linux-gnu /usr/lib/gcc -regextype posix-extended \
         -regex '.*/lib(asan|tsan|ubsan|lsan|hwasan)(_preinit)?\.(so|a|o).*' -delete \
    && rm -rf /root/.cache /var/cache/debconf/* /tmp/*

# Bibliotek som bara QGIS Desktop-delarna (Processing-diagram, symbologi-bibliotek) använder.
# OBS: serverplugin som importerar scipy, sympy, matplotlib eller plotly fungerar inte i den här avbilden.
RUN cd /usr/lib/python3/dist-packages \
    && rm -rf plotly plotly-* _plotly_future_ _plotly_utils scipy scipy-* sympy sympy-* isympy.py \
              mpmath mpmath-* matplotlib matplotlib-* mpl_toolkits \
    && rm -rf /etc/matplotlibrc /usr/share/matplotlib /usr/share/python3-plotly /usr/share/menu/python3-sympy \
              /usr/share/qgis/resources/cpt-city-qgis-min
# =============================================================================
# Slutsteg: ett enda lager. Basavbildens inställningar (ENV m.m.) följer inte med vid
# kopieringen och anges därför här. Samma värden som i 3liz/qgis-map-server.
# =============================================================================
FROM scratch
COPY --from=build / /

LABEL org.opencontainers.image.title="QGIS Server med Varnish" \
      org.opencontainers.image.description="3liz/qgis-map-server med Varnish Cache framför" \
      org.opencontainers.image.base.name="docker.io/3liz/qgis-map-server"

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LC_ALL=C.UTF-8 \
    QGIS_DISABLE_MESSAGE_HOOKS=1 \
    QGIS_NO_OVERRIDE_IMPORT=1 \
    QGSRV_DATA_PATH=/usr/local/share/qgis-server

# --- Inställningar (ändras med -e NAMN=värde eller under "environment:" i compose) --

# Varnish ................................................................
ENV VARNISH_PORT=8080 \
# Cachens storlek (RAM). Exempel: 512m, 2g. Containern behöver mer minne än så.
    VARNISH_CACHE_SIZE=256m \
# Hur länge (sekunder) en bild/ett svar cachas om anropet saknar parametern ttl.
    VARNISH_DEFAULT_TTL=60 \
# Hur länge (sekunder) Varnish väntar på QGIS Server. QGSRV_SERVER_TIMEOUT blir 1 sekund mindre.
    VARNISH_BACKEND_TIMEOUT=120 \
# Max antal samtidiga anrop till QGIS Server. Tomt = antal workers x 20.
    VARNISH_MAX_CONNECTIONS="" \
# Antal nya försök mot QGIS Server vid 503/504, samt antal omstarter av anropet.
    VARNISH_MAX_RETRIES=2 \
    VARNISH_MAX_RESTARTS=1 \
# Ett misslyckat anrop (503/504) försöks bara igen (både retries och omstart) om det är yngre än så här
# många sekunder. Anrop som redan väntat längre, t.ex. på en timeout, ger felet direkt. 10 s ryms 3 försök
# mot en backend som inte svarar alls (3 x 2 s).
    VARNISH_RETRY_MAX_AGE=10 \
# Vilka REQUEST-typer som cachas (GetCapabilities cachas alltid 60 s). Exempel: GetMap|GetLegendGraphic|GetTile
    VARNISH_CACHE_REQUESTS="GetMap|GetLegendGraphic" \
# Parametrar som tas bort ur URL:en före cachning (|-separerade). Tomt = inga.
    VARNISH_STRIP_PARAMS="time" \
# Sätt till "yes" om https hanteras av en proxy framför som inte skickar X-Forwarded-Proto.
    VARNISH_FORCE_HTTPS=no \
# Snygga adresser: <prefix>/ows/<projekt>?... blir /ows/?map=<projekt>.<filändelse>&...
# Prefix, exempel: /kartor. Filändelse: qgs eller qgz (QGIS standardformat är qgz).
    VARNISH_URL_PREFIX="" \
    VARNISH_PROJECT_EXTENSION=qgs \
# Extra Host-värde som får göra BAN (cache-rensning) utifrån. Tomt = bara inifrån containern.
    VARNISH_BAN_HOST="" \
# Adminsida för att rensa cachen i webbläsaren, på <adress>/_admin. Slås på när båda anges
# (lösenordet minst 8 tecken). Nås containern över ett nätverk: använd https framför den,
# annars skickas lösenordet i klartext.
    VARNISH_ADMIN_USER="" \
    VARNISH_ADMIN_PASSWORD="" \
# Adress som används för hälsokontroller mot QGIS Server.
    VARNISH_PROBE_URL=/ping \
# Avancerat: övriga Varnish-parametrar (trådar, keepalive m.m.).
    VARNISH_EXTRA_OPTS="-p http_gzip_support=on -p thread_pools=2 -p thread_pool_min=200 -p thread_pool_max=800 -p thread_pool_timeout=300 -p tcp_keepalive_time=60 -p tcp_keepalive_intvl=5 -p tcp_keepalive_probes=3 -p vsl_reclen=1024"

# QGIS Server ...........................................................
# Lyssnar bara inne i containern; det är Varnish som tar emot trafiken utifrån.
ENV QGSRV_SERVER_HTTP_PORT=8081 \
    QGSRV_SERVER_INTERFACES=127.0.0.1 \
# Antal QGIS-processer. Sätt gärna till antalet CPU-kärnor containern får använda.
    QGSRV_SERVER_WORKERS=2
# Fler inställningar (t.ex. QGSRV_CACHE_SIZE = antal projekt som hålls i minnet)
# finns i dokumentationen för py-qgis-server. QGIS-projekten läggs i /qgis-data.

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=15s --start-period=90s --retries=3 \
    CMD curl -fs -o /dev/null --max-time 10 "http://127.0.0.1:${VARNISH_PORT}${VARNISH_PROBE_URL}" || exit 1

# start.sh startar först QGIS Server och sedan Varnish. Kommandot nedan skickas
# vidare till basavbildens entrypoint.
ENTRYPOINT ["/usr/local/bin/start.sh"]
CMD ["qgisserver"]
