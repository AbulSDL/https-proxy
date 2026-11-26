#!/usr/bin/env bash
# Erneuert fällige Zertifikate und lädt nginx neu. Läuft per
# profineo-renew.timer; ein Fehler löst über OnFailure eine Mail aus.
#
# Endet absichtlich mit Fehler, wenn eine Instanz dieses Hosts noch kein
# certbot-Zertifikat hat - sonst bliebe das unbemerkt, weil "certbot renew"
# ohne Zertifikate einfach nichts tut und Erfolg meldet.

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
host_laden

dc run --rm certbot renew --non-interactive --quiet
rc=0

declare -A geprueft=()
for s in $SITES; do
    site_laden "$s"
    [[ -n ${geprueft[$DOMAIN]:-} ]] && continue
    geprueft[$DOMAIN]=1
    if ! zert_von_certbot "$DOMAIN"; then
        warnung "$DOMAIN ($s): kein certbot-Zertifikat - wird nicht erneuert. Holen mit: scripts/cert-issue.sh $s"
        rc=1
    fi
done

if nginx_laeuft; then
    docker exec profineo-proxy nginx -s reload
else
    warnung "nginx läuft nicht"
    rc=1
fi

exit $rc
