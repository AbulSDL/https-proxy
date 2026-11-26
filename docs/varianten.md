# Varianten: Wo laufen Proxy und Backend?

Vor dem Termin klären, welche Variante beim Kunden vorliegt - davon hängen
`BACKEND`, die nötigen Firewall-Freigaben und die Prüfung ab.

| Variante | Proxy-Host | Backend (JBoss) | `BACKEND` in `sites/<name>.env` |
|---|---|---|---|
| 1 | Linux | auf **demselben** Linux-Host | `127.0.0.1:<port>` |
| 2 | Linux | auf einem **anderen** Rechner (Windows oder Linux) | `<interne IP>:<port>` |
| 2b | ein zentraler Linux-Proxy | **mehrere** Backends/Instanzen, gleicher Hostname, je eigener Port | je Instanz eine Datei mit eigenem `LISTEN_PORT` |
| 3 | beim Kunden gibt es **nur Windows-Server** | Windows | Linux-VM als Proxy anlegen, dann wie Variante 2 |

Der Proxy selbst läuft immer unter Linux (siehe README, Voraussetzungen).
Das Backend darf auf Windows oder Linux laufen.

## Variante 1: Backend auf demselben Host

```bash
ss -ltn | grep ':28080 '                     # lauscht das Backend?
curl -s -o /dev/null -m 5 -w '%{http_code}\n' http://127.0.0.1:28080/profi/
```

Erwartet: eine Zeile bei `ss`, Antwort `200`. Der Container nutzt das Netz
des Hosts (`network_mode: host`), `127.0.0.1` ist darum der Host selbst.

Empfehlung: Das Backend nur an `127.0.0.1` binden. Sonst ist es im
internen Netz zusätzlich unverschlüsselt erreichbar.

## Variante 2: Backend auf einem anderen Rechner

Vom **Proxy-Host** aus prüfen:

```bash
curl -s -o /dev/null -m 5 -w '%{http_code}\n' http://192.0.2.10:28080/profi/
```

| Ergebnis | Ursache | Abhilfe |
|---|---|---|
| `200` | alles erreichbar | - |
| `000` nach 5 s (Timeout) | Firewall auf dem Backend-Rechner oder dazwischen | Freigabe, siehe unten |
| `000` sofort (Connection refused) | Backend lauscht nicht auf dieser Adresse | Backend läuft nicht oder nur auf `127.0.0.1` |

**Lauscht das Backend im Netz?** Auf dem Backend-Rechner:

```powershell
netstat -ano | findstr :28080        # Windows
```
```bash
ss -ltn | grep ':28080 '             # Linux
```

`0.0.0.0:28080` oder die LAN-Adresse ist richtig. Steht dort nur
`127.0.0.1:28080`, erreicht der Proxy das Backend nicht - die Bindeadresse
des Backends muss geändert werden.

**Freigabe auf dem Backend-Rechner** - nur für den Proxy, nicht für alle:

Windows (PowerShell als Administrator):

```powershell
New-NetFirewallRule -DisplayName "HTTPS-Proxy -> Backend 28080" `
    -Direction Inbound -Protocol TCP -LocalPort 28080 `
    -RemoteAddress 192.0.2.20 -Action Allow
```

Linux (ufw):

```bash
ufw allow from 192.0.2.20 to any port 28080 proto tcp
```

`192.0.2.20` = interne Adresse des Proxy-Hosts, `28080` = Backend-Port.
Liegt eine Netzwerk-Firewall zwischen Proxy und Backend (anderes Subnetz,
VLAN), braucht es dort dieselbe Freigabe - das macht der IT-Betreuer des
Kunden.

Danach die Prüfung oben wiederholen, Erwartung `200`.

## Variante 2b: Zentraler Proxy für mehrere Instanzen auf eigenen Ports

Ein Proxy-Host bedient mehrere Backends, alle unter **demselben Hostnamen**.
Unterschieden wird über den **Port**, nicht über den Namen - die Clients
sprechen `https://saas.example.com:<port>/` an. Die Backends dürfen auf
verschiedenen Rechnern liegen (auch Windows, auch in einem anderen
Netzsegment).

Je Instanz eine Datei, alle mit derselben `DOMAIN`:

```
# sites/kunde-app.env
DOMAIN=saas.example.com
LISTEN_PORT=30443
BACKEND=192.0.2.30:30080

# sites/kunde-bericht.env       (zweite Anwendung desselben Kunden, z. B. Berichtsserver)
DOMAIN=saas.example.com
LISTEN_PORT=30943
BACKEND=192.0.2.30:8082
APP_PATH=/jasperserver-pro/
```

```
# host.env
SITES="kunde-app kunde-bericht"
```

Was dabei gilt:

- **Ein Zertifikat für alle.** Es hängt an der Domain, nicht am Port.
  `cert-issue.sh` holt es einmal; für jede weitere Instanz derselben Domain
  meldet es "bereits ein certbot-Zertifikat" - dann reicht `render.sh`.
- **Port 80 bleibt Pflicht** für die Ausstellung und Erneuerung (HTTP-01),
  auch wenn kein Client je Port 80 oder 443 benutzt. Weil keine Instanz auf
  443 liegt, antwortet Port 80 außer für ACME mit 404 statt umzuleiten.
- **Firewall:** je `LISTEN_PORT` eine Weiterleitung auf den Proxy-Host, dazu
  Port 80. Liegen die Backends in einem anderen Netzsegment, braucht es dort
  eine Freigabe Proxy -> Backend-Port (ohne NAT, sonst greift eine Regel mit
  `RemoteAddress` auf dem Backend nicht) - siehe Variante 2.
- **Das Backend muss seinen äußeren Port kennen.** Erzeugt die Anwendung
  absolute Adressen, muss sie `LISTEN_PORT` als ihren Port verwenden, nicht
  den internen Backend-Port. Bei Tomcat heißen die Attribute am Konnektor
  `proxyName`/`proxyPort`, bei JBoss `proxy-name`/`proxy-port`, jeweils mit
  `scheme="https"` und `secure="true"`.
- **`cert-check.sh` prüft jede Instanz einzeln** auf ihrem Port - eine
  fehlende Freigabe zu einem Backend fällt dort als `502`/`504` auf.
- **Nur HTTP.** Protokolle wie JMS oder Remoting zwischen Client und Backend
  laufen nicht über diesen Proxy.

## Variante 3: Nur Windows-Server vorhanden

Bevor eine Lösung beim Kunden gesucht wird: Kann ein **bestehender
Linux-Proxy** (z. B. der eigene, Variante 2b) das Backend erreichen? Dann
braucht der Kunde gar keinen eigenen Proxy - nur eine Freigabe vom Proxy zu
seinem Backend.

Sonst: Docker Desktop unter Windows kann diesen Proxy nicht betreiben
(`network_mode: host`, systemd-Timer, bash). Stattdessen eine kleine
Linux-VM auf dem vorhandenen Hyper-V (oder VMware) anlegen:

- Debian 12 oder 13, ohne Desktop
- 1 vCPU, 1 GB RAM, 10 GB Platte reichen
- Netzwerk: **externer** virtueller Switch (eigene Adresse im LAN, kein NAT)
- feste IP-Adresse (kein DHCP) - auf sie zeigen Portweiterleitung und
  interner DNS
- Zeitsynchronisation aktiv lassen (TLS und Zertifikatsprüfung brauchen die
  richtige Uhrzeit)

Ab dann ist es Variante 2: die VM ist der Proxy-Host, der Windows-Server
das Backend. Weiter mit [installation.md](installation.md), Schritt 1.

**Läuft die VM auf demselben Windows-Rechner wie das Backend:**
`BACKEND=127.0.0.1:...` ist dann falsch - `127.0.0.1` ist die VM selbst.
Richtig ist die **LAN-Adresse des Windows-Rechners**, dazu die
Windows-Firewall-Regel aus Variante 2 mit der Adresse der VM als
`RemoteAddress`.

Eine Lösung ganz ohne Linux (z. B. IIS mit Application Request Routing und
win-acme) gehört nicht zu diesem Repo. Ist keine VM möglich, vorher
abstimmen.
