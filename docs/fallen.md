# Fallen

Gesammelt bei den bisherigen Umstellungen.

## nginx / Docker

- **Neustartschleife `cannot load certificate ... No such file`** - TLS-Block
  aktiv, Zertifikat noch nicht da. `render.sh` verhindert das inzwischen.
- **`docker kill` löst `restart: unless-stopped` nicht aus** - zählt als
  manueller Abbruch. Absturz testen mit `docker exec profineo-proxy nginx -s stop`.
- **`kill -9 1` im Container ist wirkungslos** - PID 1 eines Namensraums
  bekommt von innen nur Signale, für die ein Handler existiert.
- **`apt install docker` installiert `wmdocker`** (ein Dock-Programm).
  Docker aus der offiziellen Paketquelle installieren.
- **Ersetzte Datei/Verzeichnis im laufenden Container unsichtbar** - Bind-Mounts
  hängen am Inode. Darum tauscht `render.sh` nur den Inhalt von `conf.d/` aus.
  Nach einer Änderung an `nginx/nginx.conf` (z. B. durch `git pull`) erkennt
  `render.sh` das und erstellt den Container neu.
- **`certbot renew` ohne Zertifikate meldet Erfolg** - darum prüft `renew.sh`
  selbst, ob jede Instanz ein certbot-Zertifikat hat.
- **`NGINX_IMAGE`/`CERTBOT_IMAGE` aus `host.env` gelten nur über die Skripte** -
  `docker compose` liest von sich aus nur `.env`, nicht `host.env`. Die
  Skripte exportieren die Werte, ein von Hand aufgerufenes
  `docker compose up -d` nicht: Ist dort ein anderes Image eingetragen, erstellt
  compose den Container still mit dem Standard-Image aus `compose.yaml` neu.
  Mit abweichendem Image deshalb nur `scripts/render.sh` verwenden (startet
  nginx, falls er nicht läuft, und erstellt ihn nach einer geänderten
  `nginx.conf` neu) oder die Werte beim Aufruf mitgeben:
  `NGINX_IMAGE=... docker compose up -d`.

## DNS

- **AAAA-Eintrag, aber nginx nur auf IPv4** - Let's Encrypt prüft bevorzugt
  über IPv6, Ausstellung und Erneuerung schlagen fehl. `IPV6=auto` (Vorgabe in
  `host.env`) lauscht auch auf IPv6, sofern der Host es hat. Hat der Host kein
  IPv6, darf die Domain keinen AAAA-Eintrag haben.
- **`nslookup` und `dig` übergehen `/etc/hosts`** - Systemauflösung prüfen
  mit `getent hosts <name>`.
- **`localtest.me` geht in manchen Kundennetzen nicht** - Rebind-Schutz des
  DNS verwirft öffentliche Namen, die auf 127.0.0.1 zeigen. Ersatz: `/etc/hosts`.

## Arbeiten über TeamViewer

- Einfügen im Terminal `Strg+Shift+V`, Kopieren `Strg+Shift+C`
  (Markieren allein überträgt TeamViewer nicht)
- `Strg+S` friert das Terminal ein, `Strg+Q` löst es
- Bracketed Paste (`^[[200~`) abschalten: `printf '\e[?2004l'`
- Heredocs brechen, wenn `EOF` eingerückt ist
- `deb822` (`*.sources`): führendes Leerzeichen = Fortsetzungszeile
- Nach jeder erzeugten Datei eine Zählprobe (`wc -l`, `grep -c`)

```
<<EOF      Shell ersetzt $VARIABLE und $(befehl)
<<'EOF'    Shell ersetzt nichts            -> nginx.conf, Skripte
```
