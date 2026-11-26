#!/usr/bin/env bash
# Schickt Status und Protokoll einer fehlgeschlagenen systemd-Einheit per
# Mail. Aufgerufen von status-mail@.service (OnFailure der Timer-Dienste).
#
#   scripts/status-mail.sh <einheit>
#
# Versand über msmtp; Zugangsdaten liegen nur auf dem Host (/etc/msmtprc).

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
host_laden

[[ $# -eq 1 ]] || fehler "Verwendung: $0 <einheit>"
einheit=$1
[[ -n $MAIL_AN ]] || fehler "host.env: MAIL_AN fehlt"
command -v msmtp >/dev/null || fehler "msmtp fehlt (apt install msmtp)"

{
    printf 'To: %s\n' "$MAIL_AN"
    printf 'Subject: [%s] %s fehlgeschlagen\n' "$(hostname)" "$einheit"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf 'Content-Transfer-Encoding: 8bit\n\n'
    printf 'Host: %s\nZeit: %s\nRepo: %s\n\n' "$(hostname -f 2>/dev/null || hostname)" "$(date '+%F %T %Z')" "$REPO_DIR"
    systemctl status --no-pager --lines=0 "$einheit" 2>&1 || true
    printf '\n--- Protokoll (letzte 60 Zeilen) ---\n'
    journalctl --no-pager -n 60 -u "$einheit" 2>&1 || true
} | msmtp -t
