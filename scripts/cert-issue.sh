#!/usr/bin/env bash
# Holt das Let's-Encrypt-Zertifikat für eine Instanz (HTTP-01 über Port 80).
#
#   scripts/cert-issue.sh <instanz>              Trockenlauf, dann echt
#   scripts/cert-issue.sh <instanz> --trocken    nur Trockenlauf
#
# Voraussetzungen: nginx läuft, Port 80 ist aus dem Internet auf diesen
# Host weitergeleitet, die Domain zeigt öffentlich auf die Firewall.
# Prüfbar vorab auf https://letsdebug.net (Methode HTTP-01).

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[[ $# -ge 1 ]] || fehler "Verwendung: $0 <instanz> [--trocken]"
host_laden
site_laden "$1"
nur_trocken=0
[[ ${2:-} == --trocken ]] && nur_trocken=1

[[ -n $ACME_EMAIL ]] || fehler "host.env: ACME_EMAIL fehlt"
[[ " $SITES " == *" $SITE "* ]] || fehler "$SITE steht nicht in SITES (host.env) - dieser Host bedient die Instanz nicht"
nginx_laeuft || fehler "nginx läuft nicht - zuerst: scripts/render.sh && docker compose up -d"

if zert_von_certbot "$DOMAIN"; then
    info "Für $DOMAIN gibt es bereits ein certbot-Zertifikat. Erneuern übernimmt scripts/renew.sh."
    exit 0
fi

certbot_certonly() {
    dc run --rm certbot certonly --webroot -w /var/www/certbot \
        -d "$DOMAIN" --email "$ACME_EMAIL" --agree-tos --no-eff-email \
        --key-type ecdsa --non-interactive "$@"
}

info "Trockenlauf gegen die Let's-Encrypt-Testumgebung ..."
certbot_certonly --dry-run \
    || fehler "Trockenlauf fehlgeschlagen. 'Timeout during connect' = Port-80-Weiterleitung fehlt."
(( nur_trocken )) && { info "Trockenlauf erfolgreich (--trocken: kein echtes Zertifikat geholt)"; exit 0; }

# Ein Platzhalter-Zertifikat (z. B. selbst ausgestellt) liegt im Weg:
# certbot würde sonst <domain>-0001 anlegen. Nur beiseite legen, nicht
# löschen - und erst jetzt, nach dem erfolgreichen Trockenlauf.
if zert_vorhanden "$DOMAIN"; then
    ablage="letsencrypt/beiseite-$DOMAIN-$(date +%Y%m%d-%H%M%S)"
    mv "letsencrypt/live/$DOMAIN" "$ablage"
    info "Platzhalter-Zertifikat verschoben nach $ablage"
fi

if ! certbot_certonly; then
    if [[ -n ${ablage:-} ]]; then
        mv "$ablage" "letsencrypt/live/$DOMAIN"
        warnung "Platzhalter-Zertifikat zurückgelegt"
    fi
    fehler "Zertifikat konnte nicht geholt werden"
fi

info "Zertifikat für $DOMAIN geholt."
scripts/render.sh
