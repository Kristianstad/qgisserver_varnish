#!/bin/bash
# =============================================================================
# Startskript för avbilden "QGIS Server + Varnish".
#
# Gör i tur och ordning:
#   1. Kontrollerar inställningarna (miljövariablerna)
#   2. Skapar Varnish-konfigurationen från /etc/varnish/default.vcl.template
#   3. Startar QGIS Server (via basavbildens egen entrypoint) och väntar tills den svarar
#   4. Startar Varnish
#   5. Håller koll på båda: slutar en av dem fungera avslutas containern, så att
#      Docker (restart-policy) kan starta om den.
# =============================================================================
set -euo pipefail

STARTUP_TIMEOUT=120   # sekunder som QGIS Server får på sig att starta

log() { echo "[start] $*"; }
die() { echo "[start] FEL: $*" >&2; exit 1; }

# --- 1. Kontrollera inställningar ---------------------------------------------
for v in VARNISH_PORT VARNISH_BACKEND_TIMEOUT VARNISH_DEFAULT_TTL \
         VARNISH_MAX_RETRIES VARNISH_MAX_RESTARTS \
         QGSRV_SERVER_HTTP_PORT QGSRV_SERVER_WORKERS; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v måste vara ett heltal (är nu: '${!v}')."
done

# Antal samtidiga anslutningar Varnish får göra mot QGIS Server.
if [[ -z "${VARNISH_MAX_CONNECTIONS}" ]]; then
    VARNISH_MAX_CONNECTIONS=$((QGSRV_SERVER_WORKERS * 6))
fi
[[ "${VARNISH_MAX_CONNECTIONS}" =~ ^[0-9]+$ ]] || die "VARNISH_MAX_CONNECTIONS måste vara ett heltal."

# QGIS Servers timeout ska vara kortare än Varnish timeout.
if [[ -z "${QGSRV_SERVER_TIMEOUT:-}" ]]; then
    export QGSRV_SERVER_TIMEOUT=$((VARNISH_BACKEND_TIMEOUT - 1))
elif ((QGSRV_SERVER_TIMEOUT >= VARNISH_BACKEND_TIMEOUT)); then
    log "VARNING: QGSRV_SERVER_TIMEOUT (${QGSRV_SERVER_TIMEOUT}) bör vara mindre än VARNISH_BACKEND_TIMEOUT (${VARNISH_BACKEND_TIMEOUT})."
fi

# Prefix: ta bort ev. avslutande snedstreck.
VARNISH_URL_PREFIX="${VARNISH_URL_PREFIX%/}"
[[ "${VARNISH_URL_PREFIX}" =~ ^(/[A-Za-z0-9._~-]+)*$ ]] \
    || die "VARNISH_URL_PREFIX ska vara en sökväg som /kartor (är nu: '${VARNISH_URL_PREFIX}')."

[[ "${VARNISH_FORCE_HTTPS}" =~ ^(yes|no)$ ]]            || die "VARNISH_FORCE_HTTPS måste vara yes eller no."
[[ "${VARNISH_PROJECT_EXTENSION}" =~ ^(qgs|qgz)$ ]]     || die "VARNISH_PROJECT_EXTENSION måste vara qgs eller qgz."
[[ "${VARNISH_CACHE_REQUESTS}" =~ ^[A-Za-z|]+$ ]]       || die "VARNISH_CACHE_REQUESTS får bara innehålla bokstäver och | (t.ex. GetMap|GetLegendGraphic)."
[[ "${VARNISH_BAN_HOST}" =~ ^[A-Za-z0-9._:-]*$ ]]       || die "VARNISH_BAN_HOST innehåller ogiltiga tecken."
[[ "${VARNISH_PROBE_URL}" =~ ^/[^[:space:]\"]*$ ]]      || die "VARNISH_PROBE_URL måste börja med / (t.ex. /ping)."
[[ "${VARNISH_STRIP_PARAMS}" =~ ^[A-Za-z0-9_|-]*$ ]]    || die "VARNISH_STRIP_PARAMS får bara innehålla bokstäver, siffror, _ - och | (t.ex. time|nocache)."
# Tom lista = ta inte bort några parametrar (ersätt med ett namn som aldrig förekommer).
[[ -n "${VARNISH_STRIP_PARAMS}" ]] || VARNISH_STRIP_PARAMS="ingen-parameter-alls"

# Adminsida för cache-rensning: slås på när både användare och lösenord anges.
VARNISH_ADMIN_B64=""
if [[ -n "${VARNISH_ADMIN_USER:-}" || -n "${VARNISH_ADMIN_PASSWORD:-}" ]]; then
    [[ -n "${VARNISH_ADMIN_USER:-}" && -n "${VARNISH_ADMIN_PASSWORD:-}" ]] \
        || die "Både VARNISH_ADMIN_USER och VARNISH_ADMIN_PASSWORD måste anges för att slå på adminsidan."
    [[ "${VARNISH_ADMIN_USER}" =~ ^[^:[:cntrl:]]+$ ]] \
        || die "VARNISH_ADMIN_USER får inte innehålla kolon eller styrtecken."
    ((${#VARNISH_ADMIN_PASSWORD} >= 8)) || die "VARNISH_ADMIN_PASSWORD måste vara minst 8 tecken."
    VARNISH_ADMIN_B64=$(printf '%s:%s' "$VARNISH_ADMIN_USER" "$VARNISH_ADMIN_PASSWORD" | base64 -w0)
    log "Adminsidan för cache-rensning är påslagen på ${VARNISH_URL_PREFIX}/_admin"
fi

export VARNISH_MAX_CONNECTIONS VARNISH_URL_PREFIX VARNISH_STRIP_PARAMS VARNISH_ADMIN_B64

# --- 2. Skapa Varnish-konfigurationen ------------------------------------------
VCL=/etc/varnish/default.vcl
if [[ -f /etc/varnish/custom.vcl ]]; then
    log "Hittade /etc/varnish/custom.vcl – använder den i stället för den inbyggda konfigurationen."
    VCL=/etc/varnish/custom.vcl
else
    envsubst '${QGSRV_SERVER_HTTP_PORT} ${VARNISH_BACKEND_TIMEOUT} ${VARNISH_MAX_CONNECTIONS}
              ${VARNISH_PROBE_URL} ${VARNISH_BAN_HOST} ${VARNISH_STRIP_PARAMS}
              ${VARNISH_FORCE_HTTPS} ${VARNISH_URL_PREFIX} ${VARNISH_CACHE_REQUESTS}
              ${VARNISH_DEFAULT_TTL} ${VARNISH_MAX_RESTARTS} ${VARNISH_PROJECT_EXTENSION}
              ${VARNISH_ADMIN_B64}' \
        < /etc/varnish/default.vcl.template > "$VCL"
    # Filen kan innehålla inloggningsuppgifter. Varnish läser den som användaren "varnish",
    # så bara den användaren (och root) ska kunna läsa den, inte t.ex. QGIS Server.
    chown varnish:varnish "$VCL"
    chmod 600 "$VCL"
fi
# Inloggningsuppgifterna behövs inte längre: se till att QGIS Server inte ärver dem.
unset VARNISH_ADMIN_USER VARNISH_ADMIN_PASSWORD VARNISH_ADMIN_B64

# Kompilera konfigurationen som ett test, så att fel syns direkt och tydligt.
# (varnishd -C skriver mycket text även när allt är rätt, så vi visar den bara vid fel.)
if ! vcl_output=$(varnishd -C -f "$VCL" 2>&1 > /dev/null); then
    echo "$vcl_output" >&2
    die "Varnish kunde inte läsa $VCL (se felmeddelandet ovan)."
fi

# --- 3. Starta QGIS Server ------------------------------------------------------
# Basavbildens entrypoint (/docker-entrypoint.sh) startar QGIS Server som en
# vanlig, icke-privilegierad användare. "$@" är kommandot (som standard: qgisserver).
/docker-entrypoint.sh "$@" &
QGIS_PID=$!

log "Väntar på att QGIS Server ska svara på http://127.0.0.1:${QGSRV_SERVER_HTTP_PORT}${VARNISH_PROBE_URL} ..."
started=no
for ((i = 0; i < STARTUP_TIMEOUT; i++)); do
    kill -0 "$QGIS_PID" 2>/dev/null || die "QGIS Server avslutades under starten (se loggen ovan)."
    if curl -fs -o /dev/null --max-time 2 "http://127.0.0.1:${QGSRV_SERVER_HTTP_PORT}${VARNISH_PROBE_URL}"; then
        started=yes
        break
    fi
    sleep 1
done
[[ "$started" == "yes" ]] || die "QGIS Server svarade inte inom ${STARTUP_TIMEOUT} sekunder."
log "QGIS Server är igång."

# --- 4. Starta Varnish ---------------------------------------------------------
log "Startar Varnish på port ${VARNISH_PORT} (cache: ${VARNISH_CACHE_SIZE})."
# VARNISH_EXTRA_OPTS ska delas upp i flera argument, därför inga citattecken runt den.
# shellcheck disable=SC2086
varnishd -F \
    -f "$VCL" \
    -a ":${VARNISH_PORT}" \
    -s "malloc,${VARNISH_CACHE_SIZE}" \
    -p "max_retries=${VARNISH_MAX_RETRIES}" \
    -p "max_restarts=${VARNISH_MAX_RESTARTS}" \
    ${VARNISH_EXTRA_OPTS} &
VARNISH_PID=$!

# --- 5. Övervaka och stäng ner ordentligt ----------------------------------------
shutdown() {
    trap - TERM INT
    kill -TERM "$VARNISH_PID" "$QGIS_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
# "docker stop" skickar TERM: stäng ner båda processerna snyggt.
trap 'log "Stoppsignal mottagen – stänger ner."; shutdown; exit 0' TERM INT

rc=0
wait -n || rc=$?
[[ $rc -ne 0 ]] || rc=1
log "QGIS Server eller Varnish avslutades oväntat (kod $rc) – stänger ner containern."
shutdown
exit "$rc"
