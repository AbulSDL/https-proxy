#!/usr/bin/env bash
# Erzeugt nginx/conf.d/ aus host.env und sites/*.env, prüft das Ergebnis
# mit "nginx -t" und lädt nginx neu.
#
# Instanzen ohne Zertifikat bekommen nur den Port-80-Teil (ACME). Damit
# startet nginx immer - auch bevor ein Zertifikat existiert.
#
#   scripts/render.sh            erzeugen, prüfen, einspielen, neu laden
#                                (startet nginx, falls er nicht läuft)
#   scripts/render.sh --pruefen  nur erzeugen und prüfen, nichts einspielen

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

nur_pruefen=0
case ${1:-} in
    '') ;;
    --pruefen) nur_pruefen=1 ;;
    *) fehler "Verwendung: $0 [--pruefen]" ;;
esac

host_laden
mkdir -p letsencrypt certbot/www log nginx/conf.d

# IPv6: bei "auto" nur, wenn der Host IPv6 hat - sonst bricht nginx beim
# Start mit "Address family not supported" ab (nginx -t merkt das nicht).
if [[ $IPV6 == auto ]]; then
    [[ -s /proc/net/if_inet6 ]] && IPV6=1 || IPV6=0
fi
listen6() {  # listen6 <port> [zusatz]
    if (( IPV6 )); then
        printf 'listen [::]:%s%s;' "$1" "${2:+ $2}"
    else
        printf '# kein IPv6 (host.env: IPV6)'
    fi
}
info "IPv6: $( (( IPV6 )) && echo an || echo aus)"

neu=$(mktemp -d nginx/.render.XXXXXX)
trap 'rm -rf "$neu"' EXIT

declare -A domains=()      # Domain -> 1
declare -A weiterleiten=() # Domain -> 1, wenn eine Instanz mit Zertifikat auf 443 liegt
declare -A tls_ports=()    # Port -> 1
declare -A belegt=()       # "Domain:Port" -> Instanz

hsts_zeile() {
    if (( HSTS > 0 )); then
        printf 'add_header Strict-Transport-Security "max-age=%s" always;' "$HSTS"
    else
        printf '# kein HSTS (sites/%s.env: HSTS=0) - Rückweg auf HTTP bleibt offen' "$s"
    fi
}

vorlage nginx/templates/default-http.conf.tmpl LISTEN6="$(listen6 80 default_server)" \
    > "$neu/default-http.conf"

for s in $SITES; do
    site_laden "$s"

    schluessel="$DOMAIN:$LISTEN_PORT"
    [[ -z ${belegt[$schluessel]:-} ]] \
        || fehler "$s und ${belegt[$schluessel]} belegen beide $schluessel"
    belegt[$schluessel]=$s
    domains[$DOMAIN]=1

    if zert_vorhanden "$DOMAIN"; then
        vorlage nginx/templates/site.conf.tmpl \
            SITE="$s" DOMAIN="$DOMAIN" LISTEN_PORT="$LISTEN_PORT" BACKEND="$BACKEND" \
            APP_PATH="$APP_PATH" APP_PATH_OHNE="${APP_PATH%/}" \
            CLIENT_MAX_BODY_SIZE="$CLIENT_MAX_BODY_SIZE" \
            LISTEN6="$(listen6 "$LISTEN_PORT" ssl)" HSTS_ZEILE="$(hsts_zeile)" \
            > "$neu/site-$s.conf"
        tls_ports[$LISTEN_PORT]=1
        (( LISTEN_PORT == 443 )) && weiterleiten[$DOMAIN]=1
        info "  $s: https://$DOMAIN:$LISTEN_PORT$APP_PATH -> http://$BACKEND"
    else
        warnung "$s: kein Zertifikat für $DOMAIN - vorerst nur Port 80 (ACME). Danach: scripts/cert-issue.sh $s"
    fi
done

for d in "${!domains[@]}"; do
    if [[ -n ${weiterleiten[$d]:-} ]]; then
        # nginx-Variablen, nicht von der Shell zu ersetzen
        # shellcheck disable=SC2016
        aktion='return 301 https://$host$request_uri;' zweck='Weiterleitung auf HTTPS'
    else
        aktion='return 404;' zweck='404 (keine Instanz auf 443 mit Zertifikat)'
    fi
    vorlage nginx/templates/http.conf.tmpl DOMAIN="$d" HTTP_AKTION="$aktion" HTTP_ZWECK="$zweck" \
        LISTEN6="$(listen6 80)" > "$neu/http-$d.conf"
done

for p in "${!tls_ports[@]}"; do
    vorlage nginx/templates/default-tls.conf.tmpl LISTEN_PORT="$p" \
        LISTEN6="$(listen6 "$p" "ssl default_server")" > "$neu/default-tls-$p.conf"
done

# Prüfen mit genau dem Image, das auch läuft
image=$(dc config --images nginx)
docker run --rm \
    -v "$REPO_DIR/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$REPO_DIR/$neu:/etc/nginx/conf.d:ro" \
    -v "$REPO_DIR/letsencrypt:/etc/letsencrypt:ro" \
    --entrypoint nginx "$image" -t -q \
    || fehler "nginx -t schlägt fehl - nichts eingespielt (Entwurf: $neu wird gelöscht)"
info "nginx -t: in Ordnung"

(( nur_pruefen )) && { info "--pruefen: nichts eingespielt"; exit 0; }

# Inhalt austauschen, nicht das Verzeichnis: der Container hat das
# Verzeichnis eingebunden und sähe ein ersetztes Verzeichnis nicht.
mkdir -p nginx/conf.d
find nginx/conf.d -maxdepth 1 -name '*.conf' -delete
cp "$neu"/*.conf nginx/conf.d/
info "nginx/conf.d/ aktualisiert"

if nginx_laeuft; then
    # Nach "git pull" sieht der laufende Container noch die alte nginx.conf
    # (Bind-Mount hängt am Inode). Dann reicht ein Reload nicht.
    if ! docker exec profineo-proxy cat /etc/nginx/nginx.conf | cmp -s - nginx/nginx.conf; then
        dc up -d --force-recreate nginx
        info "nginx.conf geändert - Container neu erstellt"
    else
        docker exec profineo-proxy nginx -s reload
        info "nginx neu geladen"
    fi
else
    dc up -d nginx
    sleep 2
    nginx_laeuft || fehler "nginx startet nicht - siehe: docker logs profineo-proxy"
    info "nginx gestartet"
fi
