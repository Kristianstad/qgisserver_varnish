# syntax=docker/dockerfile:1
# =============================================================================
# QGIS Server + Varnish i en och samma avbild.
#
#   klient --> Varnish (port 8080, cache) --> QGIS Server (127.0.0.1:8081, bara inuti containern)
#
# Bygg:  docker build -t qgis-varnish .
# Se README.md för hur man kör och testar.
# =============================================================================
ARG QGIS_SERVER_VERSION=3.44.14
FROM 3liz/qgis-map-server:${QGIS_SERVER_VERSION}

LABEL org.opencontainers.image.title="QGIS Server med Varnish" \
      org.opencontainers.image.description="3liz/qgis-map-server med Varnish Cache framför"

# --- Installera Varnish -------------------------------------------------------
# gettext-base: ger kommandot envsubst (fyller i miljövariabler i VCL-mallen)
# curl:         används för att vänta in QGIS Server och för healthcheck
RUN apt-get update \
    && apt-get install -y --no-install-recommends varnish gettext-base curl \
    && rm -rf /var/lib/apt/lists/*

# --- Inställningar (ändras med -e NAMN=värde eller under "environment:" i compose) --

# Varnish ................................................................
ENV VARNISH_PORT=8080 \
    # Cachens storlek (RAM). Exempel: 512m, 2g. Containern behöver mer minne än så.
    VARNISH_CACHE_SIZE=256m \
    # Hur länge (sekunder) en bild/ett svar cachas om anropet saknar parametern ttl.
    VARNISH_DEFAULT_TTL=60 \
    # Hur länge (sekunder) Varnish väntar på QGIS Server. QGSRV_SERVER_TIMEOUT blir 1 sekund mindre.
    VARNISH_BACKEND_TIMEOUT=120 \
    # Max antal samtidiga anrop till QGIS Server. Tomt = antal workers x 6.
    VARNISH_MAX_CONNECTIONS="" \
    # Antal nya försök mot QGIS Server vid 503/504, samt antal omstarter av anropet.
    VARNISH_MAX_RETRIES=2 \
    VARNISH_MAX_RESTARTS=1 \
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

# --- Filer ------------------------------------------------------------------
COPY default.vcl.template /etc/varnish/default.vcl.template
# Licenstexten för filerna i det här repot (BSD-2-Clause kräver att den följer med i binär form).
COPY LICENSE /usr/share/doc/qgis-varnish/LICENSE
COPY start.sh /usr/local/bin/start.sh
# Tar bort ev. Windows-radslut (CRLF) så att skripten fungerar även om filerna
# checkats ut på Windows, och gör startskriptet körbart.
RUN sed -i 's/\r$//' /usr/local/bin/start.sh /etc/varnish/default.vcl.template \
    && chmod 755 /usr/local/bin/start.sh

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=15s --start-period=90s --retries=3 \
    CMD curl -fs -o /dev/null --max-time 10 "http://127.0.0.1:${VARNISH_PORT}${VARNISH_PROBE_URL}" || exit 1

# start.sh startar först QGIS Server och sedan Varnish. Kommandot nedan skickas
# vidare till basavbildens entrypoint.
ENTRYPOINT ["/usr/local/bin/start.sh"]
CMD ["qgisserver"]
