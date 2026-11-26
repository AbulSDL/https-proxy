#!/usr/bin/env bash
# Richtet einen Proxy-Host ein bzw. aktualisiert ihn. Mehrfach ausführbar.
#   - systemd-Einheiten (Erneuerung, Prüfung, Mail bei Fehler)
#   - logrotate für die nginx-Protokolle
# Als root ausführen, im Repo-Verzeichnis auf dem Host (z. B. /opt/profineo-proxy).

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[[ $EUID -eq 0 ]] || fehler "als root ausführen"
[[ $REPO_DIR =~ ^/[A-Za-z0-9._/-]+$ ]] || fehler "Repo-Pfad mit Sonderzeichen wird nicht unterstützt: $REPO_DIR"
host_laden

for befehl in docker openssl curl msmtp; do
    command -v "$befehl" >/dev/null || warnung "$befehl fehlt"
done
docker compose version >/dev/null 2>&1 || fehler "docker compose fehlt (Docker aus der offiziellen Paketquelle, nicht 'apt install docker')"
[[ -f /etc/msmtprc ]] || warnung "/etc/msmtprc fehlt - Fehlermails werden nicht zugestellt"

chmod 750 "$REPO_DIR"
chmod 600 host.env

for vorlage_datei in systemd/*; do
    name=$(basename "$vorlage_datei")
    sed "s|@REPO_DIR@|$REPO_DIR|g" "$vorlage_datei" > "/etc/systemd/system/$name"
    info "installiert: /etc/systemd/system/$name"
done
systemctl daemon-reload
systemctl enable --now profineo-renew.timer profineo-check.timer

cat > /etc/logrotate.d/profineo-proxy <<EOF
$REPO_DIR/log/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        docker exec profineo-proxy nginx -s reopen >/dev/null 2>&1 || true
    endscript
}
EOF
info "installiert: /etc/logrotate.d/profineo-proxy"

systemctl list-timers 'profineo-*' --no-pager
