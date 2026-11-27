# PROFI.neo HTTPS-Proxy

nginx im Container beendet TLS und leitet `/profi/` per HTTP an den JBoss
weiter. Das Repo ist eine allgemeine Vorlage **ohne Kundendaten**: Es wird
beim Kunden auf den Proxy-Host geholt, die Kundenwerte werden nur dort
eingetragen (`host.env`, `sites/<name>.env`) und nie committet.

```
Internet ──443──▶ Firewall ──▶ Proxy-Host (nginx) ──http──▶ JBoss :8080+Versatz
                                   ▲
                       80: ACME-Prüfung + Weiterleitung auf 443
```

## Aufbau

| Pfad | Inhalt | im Repo |
|---|---|---|
| `sites/<name>.env` | eine Instanz: Domain, externer Port, Backend | **nein** |
| `sites/_beispiel.env.example` | Vorlage dafür | ja |
| `host.env` | dieser Host: welche Instanzen, Mailempfänger, ACME-Konto | **nein** |
| `nginx/nginx.conf` | globale Einstellungen | ja |
| `nginx/templates/` | Vorlagen, aus denen `render.sh` erzeugt | ja |
| `nginx/conf.d/` | erzeugt - nicht von Hand ändern | nein |
| `scripts/` | render, cert-issue, renew, cert-check, status-mail, install | ja |
| `systemd/` | Timer für Erneuerung (03:42/15:42) und Prüfung (08:00), Mail bei Fehler | ja |
| `letsencrypt/`, `certbot/`, `log/` | Laufzeitdaten | nein |

## Schnellstart beim Kunden

Kurzfassung - ausführlich in [docs/installation-linux.md](docs/installation-linux.md).

```bash
git clone https://github.com/AbulSDL/https-proxy.git /opt/profineo-proxy
cd /opt/profineo-proxy
cp host.env.example host.env                       # SITES, ACME_EMAIL, MAIL_AN
cp sites/_beispiel.env.example sites/kunde.env     # DOMAIN, BACKEND
scripts/render.sh && scripts/install.sh           # render.sh startet auch nginx
scripts/cert-issue.sh kunde                        # sobald Port 80 von außen erreichbar
```

Eine Instanz:

```
DOMAIN=profi.example.com
LISTEN_PORT=443                 # Vorgabe 443
BACKEND=192.0.2.10:28080        # JBoss intern: 8080 + Portversatz
```

Meist bedient ein Host eine Instanz. Mehrere Instanzen auf einer Domain
bekommen je einen eigenen `LISTEN_PORT`. Zertifikate gibt es pro Domain.

Aktualisieren: `git pull && scripts/render.sh` - die lokalen Werte bleiben
unberührt, weil git sie nicht kennt.

## Die Befehle

```bash
scripts/render.sh              # conf.d erzeugen, nginx -t, einspielen, Reload
scripts/render.sh --pruefen    # nur erzeugen und prüfen
scripts/cert-issue.sh <name>   # Zertifikat holen (Trockenlauf zuerst)
scripts/renew.sh               # erneuern + Reload       (Timer)
scripts/cert-check.sh          # Laufzeit, Reload, App   (Timer)
scripts/install.sh             # systemd + logrotate einrichten (root)
```

Optional `HSTS=<Sekunden>` (Vorgabe 0 = aus) pro Instanz und `IPV6=auto|0|1`
in `host.env`.

`render.sh` schreibt den TLS-Teil einer Instanz nur, wenn ihr Zertifikat
schon da ist. nginx startet deshalb immer - die Neustartschleife
"cannot load certificate" kann nicht mehr entstehen.

## Neuer Host / neue Instanz

Schritt für Schritt vom leeren Host bis zum umgestellten JBoss:

- Linux (Varianten A-C), mit Testlauf in einer VM:
  [docs/installation-linux.md](docs/installation-linux.md)
- Nur Windows (Variante D, Caddy, noch ungetestet):
  [docs/installation-windows.md](docs/installation-windows.md)
- Weitere Instanz auf einem eingerichteten Host:
  [docs/neue-instanz.md](docs/neue-instanz.md)
- Welche Variante passt: [docs/varianten.md](docs/varianten.md)

Die Umstellung des Backends selbst ist nicht Teil dieses Repos (interne
Anleitung).

## Voraussetzungen auf dem Host

Debian 12/13, bash ≥ 4, Docker mit Compose-Plugin aus der offiziellen
Paketquelle, `openssl`, `curl`, `msmtp` (`/etc/msmtprc` lokal, nie im Repo).

**Der Proxy-Host muss Linux sein.** Windows (auch mit Docker Desktop)
geht nicht: `network_mode: host`, systemd-Timer und die bash-Skripte
setzen einen Linux-Host voraus. Für Kunden, die nur Windows wollen, gibt
es statt dieses Aufbaus Caddy (`windows/`, Variante D). Das Backend (JBoss) selbst darf auf
einem Windows-Rechner laufen - der Proxy erreicht ihn über `BACKEND`.

Wird das Repo unter Windows geklont und von dort auf den Host kopiert,
sorgt `.gitattributes` dafür, dass die Skripte LF-Zeilenenden behalten
(sonst: `$'\r': command not found`).
