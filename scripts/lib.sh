# shellcheck shell=bash
# Gemeinsame Funktionen für alle Skripte. Wird per "source" geladen.
# Erwartet bash >= 4 (Debian: ja; macOS-Standard-bash 3.2: nein).

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_DIR"

fehler() { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }
warnung() { printf 'WARNUNG: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

# Liest KEY=VALUE-Zeilen, ohne die Datei als Shell-Code auszuführen.
# Nur die übergebenen Schlüssel werden gesetzt, alle anderen ignoriert.
#   env_lesen <datei> KEY1 KEY2 ...
env_lesen() {
    local datei=$1; shift
    local erlaubt=" $* " zeile key wert
    [[ -f $datei ]] || fehler "$datei fehlt"
    while IFS= read -r zeile || [[ -n $zeile ]]; do
        zeile=${zeile%$'\r'}
        [[ $zeile =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $zeile =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || fehler "$datei: ungültige Zeile: $zeile"
        key=${BASH_REMATCH[1]}
        wert=${BASH_REMATCH[2]}
        # umschließende Anführungszeichen entfernen, sonst Kommentar am Zeilenende
        if [[ $wert =~ ^\"(.*)\"$ || $wert =~ ^\'(.*)\'$ ]]; then
            wert=${BASH_REMATCH[1]}
        else
            [[ $wert =~ ^(.*[^[:space:]])?[[:space:]]+#.*$ ]] && wert=${BASH_REMATCH[1]}
            wert=${wert%"${wert##*[![:space:]]}"}
        fi
        [[ $erlaubt == *" $key "* ]] || continue
        printf -v "$key" '%s' "$wert"
    done < "$datei"
}

# host.env: Einstellungen dieses Proxy-Hosts
host_laden() {
    # ACME_EMAIL und MAIL_AN nutzen erst die aufrufenden Skripte
    # shellcheck disable=SC2034
    ACME_EMAIL='' MAIL_AN='' SITES='' WARN_DAYS=20
    NGINX_IMAGE='' CERTBOT_IMAGE='' IPV6=auto
    env_lesen host.env ACME_EMAIL MAIL_AN SITES WARN_DAYS NGINX_IMAGE CERTBOT_IMAGE IPV6
    [[ -n $SITES ]] || fehler "host.env: SITES ist leer (welche Instanzen bedient dieser Host?)"
    [[ $WARN_DAYS =~ ^[0-9]+$ ]] || fehler "host.env: WARN_DAYS muss eine Zahl sein"
    [[ $IPV6 =~ ^(auto|0|1)$ ]] || fehler "host.env: IPV6 muss auto, 0 oder 1 sein"
    # Leere Werte nicht an compose weitergeben, sonst greifen dort die Vorgaben nicht
    if [[ -n $NGINX_IMAGE ]]; then export NGINX_IMAGE; else unset NGINX_IMAGE; fi
    if [[ -n $CERTBOT_IMAGE ]]; then export CERTBOT_IMAGE; else unset CERTBOT_IMAGE; fi
    local s
    for s in $SITES; do
        [[ -f sites/$s.env ]] || fehler "host.env: Instanz '$s' in SITES, aber sites/$s.env fehlt"
    done
}

# sites/<name>.env: eine Instanz. Setzt die Variablen neu, damit nichts
# von der vorherigen Instanz übrig bleibt, und prüft jeden Wert.
site_laden() {
    SITE=$1
    [[ $SITE =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fehler "ungültiger Instanzname: $SITE"
    DOMAIN='' LISTEN_PORT=443 BACKEND='' APP_PATH=/profi/ CLIENT_MAX_BODY_SIZE=50m CHECK_APP=1 HSTS=0
    env_lesen "sites/$SITE.env" DOMAIN LISTEN_PORT BACKEND APP_PATH CLIENT_MAX_BODY_SIZE CHECK_APP HSTS

    [[ $DOMAIN =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
        || fehler "sites/$SITE.env: DOMAIN ungültig: '$DOMAIN'"
    if ! [[ $LISTEN_PORT =~ ^[0-9]{1,5}$ ]] || (( LISTEN_PORT < 1 || LISTEN_PORT > 65535 )); then
        fehler "sites/$SITE.env: LISTEN_PORT ungültig: '$LISTEN_PORT'"
    fi
    (( LISTEN_PORT != 80 )) || fehler "sites/$SITE.env: Port 80 ist für ACME und Weiterleitung reserviert"
    [[ $BACKEND =~ ^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\]):[0-9]{1,5}$ ]] \
        || fehler "sites/$SITE.env: BACKEND muss host:port sein (IPv6: [addr]:port), ist: '$BACKEND'"
    [[ $APP_PATH =~ ^/[A-Za-z0-9._~/-]*/$ ]] \
        || fehler "sites/$SITE.env: APP_PATH muss mit / beginnen und enden, ist: '$APP_PATH'"
    [[ $CLIENT_MAX_BODY_SIZE =~ ^[0-9]+[kKmMgG]?$ ]] \
        || fehler "sites/$SITE.env: CLIENT_MAX_BODY_SIZE ungültig: '$CLIENT_MAX_BODY_SIZE'"
    [[ $CHECK_APP =~ ^[01]$ ]] || fehler "sites/$SITE.env: CHECK_APP muss 0 oder 1 sein"
    [[ $HSTS =~ ^[0-9]{1,9}$ ]] || fehler "sites/$SITE.env: HSTS muss eine Zahl (Sekunden, 0 = aus) sein"
}

# Liegt ein Zertifikat (egal welcher Herkunft) für die Domain vor?
zert_vorhanden() { [[ -e letsencrypt/live/$1/fullchain.pem && -e letsencrypt/live/$1/privkey.pem ]]; }

# Wird es von certbot verwaltet (also auch erneuert)?
zert_von_certbot() { [[ -f letsencrypt/renewal/$1.conf ]]; }

# Ersetzt {{NAME}} in einer Vorlage. Werte sind vorher geprüft; die
# Anführungszeichen verhindern, dass bash 5.2 ein "&" im Wert auswertet.
#   vorlage <datei> NAME=wert ...
vorlage() {
    local datei=$1 text paar
    shift
    text=$(<"$datei")
    for paar in "$@"; do
        text=${text//"{{${paar%%=*}}}"/"${paar#*=}"}
    done
    [[ $text != *'{{'* ]] || fehler "$datei: nicht ersetzter Platzhalter übrig"
    printf '%s\n' "$text"
}

dc() { docker compose "$@"; }

nginx_laeuft() { [[ $(docker inspect -f '{{.State.Running}}' profineo-proxy 2>/dev/null) == true ]]; }
