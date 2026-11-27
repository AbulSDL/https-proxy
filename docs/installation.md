# Installation beim Kunden - Linux (Varianten A-C)

Nur Windows (Variante D, Caddy): [installation-windows.md](installation-windows.md).

Vom leeren Debian-Host bis zum umgestellten JBoss. Die Reihenfolge ist so
gewählt, dass bis einschließlich Zertifikat nichts am laufenden Betrieb
ändert - erst Schritt 8 (JBoss umstellen) bringt einen kurzen Ausfall.

Alle Befehle als **root** auf dem Proxy-Host (`sudo -i`). Kundenwerte
werden **nur dort** eingetragen, nie ins Repo.

Weitere Instanz auf einem schon eingerichteten Host:
[neue-instanz.md](neue-instanz.md). Vorher ausprobieren in einer VM:
[test-vm.md](test-vm.md).

## Voraussetzung: Port 80 und 443 von außen erreichbar

Ohne diese zwei Freigaben gibt es kein Zertifikat bzw. keinen Zugriff -
**vor dem Termin** beim Kunden beauftragen (Portweiterleitung auf den
Proxy-Host).

| Port | Wofür | Wer greift zu | Wie lange offen |
|---|---|---|---|
| **80** (HTTP) | Let's-Encrypt-Prüfung | Server von Let's Encrypt aus dem Internet | **dauerhaft** |
| **443** (HTTPS) | die Anwendung | Browser, iOS- und Android-App, MDE-Geräte | dauerhaft |

**Warum Port 80:**

- Let's Encrypt stellt ein Zertifikat nur aus, wenn wir zeigen, dass die
  Domain zu uns gehört. Dafür ruft es von mehreren Standorten im Internet
  eine Prüfdatei unter `http://<domain>/.well-known/acme-challenge/` ab.
  Dieses Verfahren (HTTP-01) schreibt **Port 80** fest vor - ein anderer
  Port ist nicht möglich.
- Die Adressen der Let's-Encrypt-Server sind nicht fest und nicht
  veröffentlicht. Eine Freigabe nur für bestimmte Absender geht deshalb
  nicht; Port 80 muss für alle offen sein.
- Zertifikate gelten 90 Tage und werden etwa alle 60 Tage auf demselben
  Weg erneuert. Wird Port 80 nach der Ausstellung geschlossen, läuft das
  Zertifikat rund zwei Monate später ab - dann melden Browser und Apps
  einen Zertifikatsfehler und die Anwendung ist nicht mehr nutzbar.
- Das Offenhalten ist unbedenklich: Auf Port 80 liefert der Proxy nur die
  Prüfdatei aus und leitet alles andere auf HTTPS um. Anwendungsdaten
  laufen dort nicht, der JBoss ist über Port 80 nicht erreichbar.

**Warum Port 443:**

- Darüber läuft die Anwendung selbst, verschlüsselt. Clients rufen
  `https://<domain>/profi/` ohne Portnummer auf - das ist Port 443.
- Das gilt für **alle** Clients, nicht nur für iOS: Browser, iOS- und
  Android-App, MDE-Geräte, Schnittstellen.
- Gerade die Apps brauchen HTTPS mit einem gültigen Zertifikat: iOS lässt
  Apps grundsätzlich nur noch über HTTPS kommunizieren (App Transport
  Security), Android sperrt unverschlüsseltes HTTP ab Version 9
  standardmäßig ebenfalls. Ein selbst ausgestelltes Zertifikat lehnen
  beide ab - darum Let's Encrypt.
- Von außen nötig, sobald Geräte außerhalb des Firmennetzes arbeiten
  (Mobilfunk, Außendienst, Homeoffice). Arbeiten wirklich alle Geräte nur
  im Firmen-WLAN, reicht 443 intern (Split-DNS) - **Port 80 muss trotzdem
  von außen offen sein**, sonst gibt es kein Zertifikat.
- Mehrere Instanzen auf einer Domain mit eigenem `LISTEN_PORT`
  ([varianten.md](varianten.md)): dieser Port statt oder zusätzlich zu
  Port 443. Port 80 bleibt in jedem Fall Pflicht.

## 0. Vorab klären (vor dem Termin)

- **Variante:** A (Proxy und JBoss auf SRV), B (eigener Linux-Proxy beim
  Kunden, JBoss auf Windows), C (SRV als Proxy für einen JBoss beim
  Kunden, über VPN)? Davon hängen `BACKEND` und die Firewall-Freigaben
  ab - [varianten.md](varianten.md). D (nur Windows, mit Caddy) nutzt
  diese Anleitung nicht. Bei A und C wird auf SRV nur eine Instanz
  ergänzt: [neue-instanz.md](neue-instanz.md).
- **Kundenwerte:** externer Name (z. B. `profi.kunde.at`), interner JBoss
  `host:port` (`8080 + Portversatz`, z. B. `10.0.0.5:28080`)
- **Beim Kunden beauftragen:**
  ```
  Firewall:   <öffentliche IP>:80  -> <Proxy-Host>:80    DAUERHAFT offen
              <öffentliche IP>:443 -> <Proxy-Host>:443
  DNS öffentlich: <domain>  A  <öffentliche IP>
  DNS intern:     <domain>  A  <Proxy-Host>             (Split-DNS)
  Proxy-Host: feste Adresse (kein DHCP), Debian 12 oder 13
  ```
  Warum Port 80 dauerhaft offen bleibt: siehe oben. Hat die Domain einen
  AAAA-Eintrag, braucht der Host auch IPv6.
- **Wer spricht den JBoss heute direkt an?** MDE-Geräte, Verknüpfungen,
  Schnittstellen, Webservice-Clients. Nach der Umstellung des Backends
  zeigen alle Verweise auf den externen Namen - diese Clients müssen
  vorher umgestellt werden.

## 1. Software installieren

```bash
apt update && apt install -y ca-certificates curl openssl git msmtp nano
```

Docker **nur aus der offiziellen Paketquelle** - `apt install docker`
installiert ein ganz anderes Programm:

```bash
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
docker compose version      # muss eine Version zeigen
```

Ports 80 und 443 müssen frei sein (der Container nutzt das Netz des Hosts):

```bash
ss -tlnp | grep -E ':(80|443) '     # keine Ausgabe = frei
```

## 2. Fehlermails einrichten (msmtp)

```bash
nano /etc/msmtprc
```

```
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log

account default
host smtp.example.com
port 587
from proxy@example.com
user proxy@example.com
password GEHEIM
```

```bash
chmod 600 /etc/msmtprc
printf 'To: du@example.com\nSubject: Test\n\nTest\n' | msmtp -t   # Mail muss ankommen
```

## 3. Repo klonen

Das Repo ist öffentlich, Klonen braucht keine Anmeldung:

```bash
git clone https://github.com/AbulSDL/https-proxy.git /opt/profineo-proxy
cd /opt/profineo-proxy
```

Kein Zugriff auf GitHub (z. B. nur TeamViewer): bei dir
`git archive -o proxy.zip HEAD`, übertragen, nach `/opt/profineo-proxy`
entpacken.

## 4. Kundenwerte eintragen

```bash
cp host.env.example host.env
cp sites/_beispiel.env.example sites/kunde.env
nano host.env
nano sites/kunde.env
```

`host.env`:

```
SITES=kunde                 # Name der Datei in sites/ (ohne .env)
ACME_EMAIL=admin@kunde.at   # Let's-Encrypt-Konto, bekommt Ablaufwarnungen
MAIL_AN=du@example.com      # Empfänger der Fehlermails
IPV6=auto
```

`sites/kunde.env`:

```
DOMAIN=profi.kunde.at
BACKEND=10.0.0.5:28080      # JBoss intern
```

Alles andere hat passende Vorgaben (Port 443, Pfad `/profi/`, HSTS aus).

**Erreicht der Proxy das Backend?** Mit dem Wert aus `BACKEND`:

```bash
curl -s -o /dev/null -m 5 -w '%{http_code}\n' http://10.0.0.5:28080/profi/
```

Erwartet: `200` oder eine Weiterleitung wie `302` (JBoss schickt oft
zuerst zur Anmeldung). Bei `000` erst die Ursache beheben (Firewall,
Bindeadresse), sonst liefert der Proxy später nur `502` - siehe
[varianten.md](varianten.md).

## 5. nginx starten

`render.sh` erzeugt die Konfiguration, prüft sie und startet den Container:

```bash
scripts/render.sh           # endet mit "nginx gestartet"
docker ps                   # profineo-proxy muss "Up" sein
```

Nicht `docker compose up -d` vor dem ersten `render.sh` - ohne erzeugte
Konfiguration fehlt nginx der Port-80-Teil.

Die Warnung `kein Zertifikat ... vorerst nur Port 80` ist hier **normal**.

Kurztest von außen (z. B. vom Handy ohne WLAN):

```bash
mkdir -p certbot/www/.well-known/acme-challenge   # legt render.sh nicht an
echo ok > certbot/www/.well-known/acme-challenge/test
```

`http://profi.kunde.at/.well-known/acme-challenge/test` muss `ok` zeigen.
Danach:

```bash
rm certbot/www/.well-known/acme-challenge/test
```

## 6. Timer und logrotate einrichten

```bash
scripts/install.sh
```

Am Ende müssen `profineo-renew.timer` und `profineo-check.timer` gelistet
sein. Fehlermail testen:

```bash
systemctl start status-mail@profineo-check.service
```

Bis das Zertifikat da ist, meldet `renew.sh` zweimal täglich per Mail,
dass die Instanz kein certbot-Zertifikat hat. Das ist gewollt und hört
nach Schritt 7 von selbst auf.

## 7. Zertifikat holen

Erst wenn der Test aus Schritt 5 von außen klappt (zusätzlich prüfbar auf
https://letsdebug.net, Methode HTTP-01):

```bash
scripts/cert-issue.sh kunde --trocken   # nur Test gegen die Let's-Encrypt-Testumgebung
scripts/cert-issue.sh kunde             # echt, danach automatisch render + Reload
scripts/cert-check.sh                   # alles muss "ok" zeigen
```

Ein vorher abgelegtes Platzhalter-Zertifikat wird dabei nach
`letsencrypt/beiseite-*` verschoben, nicht gelöscht.

## 8. Backend umstellen (angekündigter Ausfall)

Am JBoss-Rechner, nicht am Proxy - nach der **internen Anleitung**
(nicht in diesem Repo). Das Backend muss wissen, dass es hinter einem
HTTPS-Proxy steht: Verweise (`Location`) müssen auf `https://<extern>/`
zeigen, das Sitzungscookie muss `Secure` tragen. Sonst gelingt die
Anmeldung, und der erste Klick führt ins Leere.

Abschlusstest: `https://profi.kunde.at/profi/` im Browser, anmelden,
mehrmals klicken. Dann noch einmal `scripts/cert-check.sh`.

## 9. Optional: HSTS

Erst wenn der Rückweg (alter JBoss-Stand, HTTP) nicht mehr gebraucht wird -
Browser merken sich HSTS bis zum Ablauf: `HSTS=31536000` in
`sites/kunde.env`, dann `scripts/render.sh`.

## Später aktualisieren

```bash
cd /opt/profineo-proxy && git pull && scripts/render.sh
```

`host.env` und `sites/*.env` bleiben unberührt, weil git sie nicht kennt.
Hat sich `nginx/nginx.conf` geändert, erstellt `render.sh` den Container
selbst neu (ein Reload sähe die neue Datei nicht).

## Wenn etwas nicht geht

| Meldung | Ursache |
|---|---|
| `Timeout during connect` bei cert-issue | Port 80 nicht von außen auf den Host weitergeleitet |
| `nginx startet nicht` / `nginx läuft nicht` | `docker logs profineo-proxy` lesen, `scripts/render.sh` erneut |
| cert-issue scheitert trotz offenem Port 80 | AAAA-Eintrag der Domain, aber kein IPv6 am Host |
| Anmeldung geht, erster Klick führt ins Leere | JBoss noch nicht umgestellt (Schritt 8) |
| `Anwendung antwortet mit '502'` | `BACKEND` falsch oder JBoss läuft nicht |

Mehr in [fallen.md](fallen.md).
