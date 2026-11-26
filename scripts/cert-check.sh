#!/usr/bin/env bash
# Prüft jede Instanz dieses Hosts:
#   - Restlaufzeit des Zertifikats (Schwelle WARN_DAYS aus host.env)
#   - liefert nginx dasselbe Zertifikat aus, das auf der Platte liegt?
#     (sonst fehlt nach einer Erneuerung der Reload)
#   - antwortet die Anwendung unter APP_PATH? (abschaltbar mit CHECK_APP=0)
# Läuft per profineo-check.timer; Rückgabe 1 löst über OnFailure eine Mail aus.

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
host_laden
command -v openssl >/dev/null || fehler "openssl fehlt (apt install openssl)"
command -v curl >/dev/null || fehler "curl fehlt (apt install curl)"

rc=0
problem() { printf 'PROBLEM  %s\n' "$*"; rc=1; }
ok() { printf 'ok       %s\n' "$*"; }

jetzt=$(date +%s)
for s in $SITES; do
    site_laden "$s"
    ziel="$s ($DOMAIN:$LISTEN_PORT)"

    if ! zert_vorhanden "$DOMAIN"; then
        problem "$ziel: kein Zertifikat"
        continue
    fi

    datei=letsencrypt/live/$DOMAIN/cert.pem
    [[ -e $datei ]] || datei=letsencrypt/live/$DOMAIN/fullchain.pem
    ende_datei=$(openssl x509 -in "$datei" -noout -enddate | cut -d= -f2)
    tage=$(( ($(date -d "$ende_datei" +%s) - jetzt) / 86400 ))
    herkunft=certbot
    zert_von_certbot "$DOMAIN" || herkunft='NICHT von certbot (wird nicht erneuert)'
    if (( tage < WARN_DAYS )); then
        problem "$ziel: Zertifikat läuft in $tage Tagen ab ($ende_datei), $herkunft"
    else
        ok "$ziel: Zertifikat noch $tage Tage, $herkunft"
    fi

    ende_live=$(openssl s_client -connect "127.0.0.1:$LISTEN_PORT" -servername "$DOMAIN" </dev/null 2>/dev/null \
                | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
    if [[ -z $ende_live ]]; then
        problem "$ziel: keine TLS-Antwort auf 127.0.0.1:$LISTEN_PORT"
        continue
    elif [[ $ende_live != "$ende_datei" ]]; then
        problem "$ziel: nginx liefert ein anderes Zertifikat aus (bis $ende_live) als auf der Platte liegt - Reload fehlt?"
    fi

    if (( CHECK_APP )); then
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 \
               --resolve "$DOMAIN:$LISTEN_PORT:127.0.0.1" "https://$DOMAIN:$LISTEN_PORT$APP_PATH" || true)
        if [[ $code =~ ^[23] ]]; then
            ok "$ziel: Anwendung antwortet ($code)"
        else
            problem "$ziel: Anwendung antwortet mit '$code' auf $APP_PATH (Backend $BACKEND)"
        fi
    fi
done

exit $rc
