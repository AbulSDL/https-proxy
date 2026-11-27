# Varianten: Wo laufen Proxy und JBoss?

Vor dem Termin klären, welche Variante vorliegt - davon hängen `BACKEND`,
die Firewall-Freigaben und die Prüfung ab.

| Variante | Proxy | JBoss | Weiterleitung an |
|---|---|---|---|
| A | **SRV** (unser Linux-Server) | Instanzen auf **SRV** selbst | `127.0.0.1:<port>` |
| B | Linux-Server oder Linux-VM **beim Kunden** | Windows-Server beim Kunden | `<LAN-IP des JBoss>:<port>` |
| C | **SRV** | Windows-Server **beim Kunden** | `<IP des JBoss, über VPN erreichbar>:<port>` |
| D | Caddy **auf dem Windows-Server des JBoss** | derselbe Windows-Server | `127.0.0.1:<port>` |

**A bis C nutzen dieses Repo** (Linux, Docker, nginx, certbot). Die
Weiterleitung steht dort als `BACKEND` in `sites/<name>.env`.

**D ist für Kunden, die nur Windows wollen.** Dort läuft statt
nginx und certbot [Caddy](https://caddyserver.com) als Windows-Dienst - ein
Programm, das Zertifikate selbst holt und erneuert. Die Skripte dieses
Repos gibt es dort nicht; Prüfung und Fehlermail übernimmt
`windows/pruefung.ps1`. Anleitung:
[installation-windows.md](installation-windows.md) (noch ungetestet).

Reihenfolge der Empfehlung: A oder C (nichts beim Kunden), dann B (auch als
Linux-VM auf dem Windows-Server), erst dann D.

**Auf SRV (A und C) laufen mehrere Instanzen** in einem Proxy: je Instanz
eine Datei in `sites/`, alle Namen in `SITES` in `host.env`. Wie sie sich
unterscheiden (eigene Domain oder eigener Port), steht unter
[Mehrere Instanzen auf einem Proxy](#mehrere-instanzen-auf-einem-proxy).

## Prüfung: Erreicht der Proxy den JBoss?

Vom **Proxy-Host** aus, mit dem Wert aus `BACKEND`:

```bash
curl -s -o /dev/null -m 5 -w '%{http_code}\n' http://<BACKEND>/profi/
```

| Ergebnis | Bedeutung | Abhilfe |
|---|---|---|
| `200`, `302` o. ä. (2xx/3xx) | erreichbar - JBoss leitet oft auf die Anmeldung weiter | - |
| `404` | JBoss erreichbar, aber falscher Pfad | `APP_PATH` prüfen |
| `000` nach 5 s (Timeout) | Firewall auf dem JBoss-Rechner oder dazwischen, VPN fehlt | Freigabe, siehe unten |
| `000` sofort (Connection refused) | JBoss lauscht nicht auf dieser Adresse | läuft nicht oder nur auf `127.0.0.1` |

## Variante A: Proxy und JBoss auf SRV

```bash
ss -ltn | grep ':28080 '        # lauscht die Instanz?
```

`127.0.0.1` ist SRV selbst, weil der Container das Netz des Hosts nutzt
(`network_mode: host`).

Empfehlung: Die JBoss-Instanzen nur an `127.0.0.1` binden. Sonst sind sie
im internen Netz zusätzlich unverschlüsselt erreichbar.

**Läuft auf SRV schon ein nginx (oder Apache)?**

```bash
ss -tlnp | grep -E ':(80|443) '
```

Steht dort ein Prozess, kann der Container nicht starten - Port 80 und 443
gehören genau einem Programm. Dann nicht beide parallel betreiben, sondern
die bestehenden Einträge als Instanzen in `sites/` übernehmen und den alten
nginx erst beim Umschalten stoppen (`systemctl disable --now nginx`).
Vorher abstimmen, was der alte nginx sonst noch ausliefert.

## Variante B: Eigener Linux-Proxy beim Kunden

Der Kunde stellt einen Linux-Server oder eine Linux-VM bereit (siehe
unten), der JBoss läuft auf einem Windows-Server im selben Netz. Weiter mit
[installation-linux.md](installation-linux.md); `BACKEND` ist die LAN-Adresse des
Windows-Servers.

**Lauscht der JBoss im Netz?** Auf dem Windows-Server:

```powershell
netstat -ano | findstr :28080
```

`0.0.0.0:28080` oder die LAN-Adresse ist richtig. Steht dort nur
`127.0.0.1:28080`, erreicht der Proxy den JBoss nicht - die Bindeadresse
muss geändert werden.

**Freigabe auf dem Windows-Server** - nur für den Proxy, nicht für alle
(PowerShell als Administrator):

```powershell
New-NetFirewallRule -DisplayName "HTTPS-Proxy -> JBoss 28080" `
    -Direction Inbound -Protocol TCP -LocalPort 28080 `
    -RemoteAddress 192.0.2.20 -Action Allow
```

`192.0.2.20` = Adresse des Proxy-Hosts, `28080` = JBoss-Port. Liegt eine
Netzwerk-Firewall zwischen Proxy und JBoss (anderes Subnetz, VLAN), braucht
es dort dieselbe Freigabe - das macht der IT-Betreuer des Kunden.

### Linux-VM statt eigenem Server

Hat der Kunde keinen Linux-Server, genügt eine kleine VM - auf dem
vorhandenen Hypervisor (Hyper-V, VMware), auch auf dem Windows-Server des
JBoss selbst. Ist der Windows-Server selbst eine VM, die Linux-VM
**daneben** auf demselben Hypervisor anlegen, nicht darin.

- Debian 12 oder 13, ohne Desktop
- 1 vCPU, 1 GB RAM, 10 GB Platte reichen
- Netzwerk: **externer** virtueller Switch (eigene Adresse im LAN, kein NAT)
- feste IP-Adresse - auf sie zeigen Portweiterleitung und interner DNS
- Zeitsynchronisation aktiv lassen (TLS braucht die richtige Uhrzeit)
- automatischer Start mit dem Host (Hyper-V: "Automatische Startaktion" -
  "Immer automatisch starten")

Läuft die VM auf demselben Rechner wie der JBoss: `BACKEND=127.0.0.1:...`
ist falsch - `127.0.0.1` ist die VM selbst. Richtig ist die LAN-Adresse des
Windows-Servers, dazu die Firewall-Regel oben mit der Adresse der VM.

Nicht empfohlen: Docker Desktop (kann `network_mode: host`, systemd und die
Timer nicht) und WSL (läuft nur, solange jemand angemeldet ist; NAT mit
wechselnder Adresse).

## Variante C: SRV als Proxy für einen JBoss beim Kunden

Die Clients sprechen den Namen auf SRV an, SRV leitet an den Windows-Server
beim Kunden weiter. Beim Kunden wird kein Proxy installiert.

- **Nur über VPN.** Zwischen Proxy und JBoss läuft unverschlüsseltes HTTP
  (Anmeldedaten, Sitzungscookies). Das darf nicht offen über das Internet
  gehen - es braucht eine Site-to-Site-VPN-Verbindung von SRV ins Netz des
  Kunden. `BACKEND` ist die interne Adresse des JBoss, wie sie über das VPN
  erreichbar ist.
- **Freigabe beim Kunden:** Windows-Firewall-Regel wie in Variante B, als
  `RemoteAddress` die Adresse, mit der SRV über das VPN ankommt. Wird im
  VPN genattet, ist das nicht die Adresse von SRV - mit dem IT-Betreuer
  klären.
- **DNS und Firewall zeigen auf SRV,** nicht auf den Kunden: der öffentliche
  Name des Kunden (oder ein Name unter unserer Domain) bekommt die
  öffentliche Adresse von SRV.
- **Leitung:** Jede Anfrage geht Client -> SRV -> VPN -> Kunde und zurück.
  Fällt das VPN aus, meldet der Proxy `502`/`504`; `cert-check.sh` meldet
  das ebenfalls.

Die Prüfung von oben **auf SRV** ausführen, wenn das VPN steht.

## Variante D: Caddy auf dem Windows-Server des JBoss

Der Kunde will nur Windows und hat einen Server, auf dem der JBoss läuft.
Caddy kommt als Windows-Dienst auf **denselben** Server.

```
profi.kunde.at {
    handle /profi/* {
        reverse_proxy 127.0.0.1:28080
    }
    respond 404
}
```

- Weiterleitung an `127.0.0.1` - der JBoss kann (und soll) nur lokal
  lauschen, eine Firewall-Regel für den JBoss-Port entfällt.
- **Port 80 und 443 müssen frei sein.** Auf Windows Server belegt oft IIS
  Port 80: `netstat -ano | findstr ":80 :443"`.
- Firewall und DNS wie bei den anderen Varianten, nur auf diesen Server;
  Port 80 bleibt dauerhaft offen (Erneuerung).
- Caddy leitet HTTP selbst auf HTTPS um (Code `308`) und gibt Host und
  `X-Forwarded-Proto` von selbst weiter. Der JBoss wird genauso umgestellt
  wie bei den anderen Varianten.
- **Fehlt gegenüber diesem Repo:** Ablaufwarnung per Mail und Prüfung, ob
  der JBoss antwortet - unter Windows als geplante Aufgabe nachzubauen.

Ein eigener Windows-Server nur für den Proxy ist nicht vorgesehen: Er
kostet Lizenz und Wartung, ohne mehr zu können als D. Steht ein zweiter
Rechner zur Verfügung, dort eine Linux-VM einrichten (Variante B).

## Mehrere Instanzen auf einem Proxy

Die Instanzen unterscheiden sich für die Clients auf zwei Arten:

**Eigene Domain je Instanz** (`profi.kunde1.at`, `profi.kunde2.at`): alle
auf Port 443, je Domain ein eigenes Zertifikat. Für die Clients am
einfachsten.

**Eine Domain, eigener Port je Instanz** (`https://saas.example.com:30443/`):

```
# sites/kunde-app.env
DOMAIN=saas.example.com
LISTEN_PORT=30443
BACKEND=127.0.0.1:30080

# sites/kunde-bericht.env       (zweite Anwendung desselben Kunden)
DOMAIN=saas.example.com
LISTEN_PORT=30943
BACKEND=127.0.0.1:8082
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
- **Port 80 bleibt Pflicht** für Ausstellung und Erneuerung, auch wenn kein
  Client Port 80 oder 443 benutzt. Liegt keine Instanz auf 443, antwortet
  Port 80 außer für ACME mit 404 statt umzuleiten.
- **Firewall:** je `LISTEN_PORT` eine Weiterleitung auf den Proxy-Host, dazu
  Port 80.
- **Der JBoss muss seinen äußeren Port kennen.** Erzeugt die Anwendung
  absolute Adressen, muss sie `LISTEN_PORT` als ihren Port verwenden, nicht
  den internen Port (JBoss: `proxy-name`/`proxy-port` mit `scheme="https"`
  und `secure="true"`; Tomcat: `proxyName`/`proxyPort`).
- **`cert-check.sh` prüft jede Instanz einzeln** auf ihrem Port - ein nicht
  erreichbarer JBoss fällt dort als `502`/`504` auf.
- **Nur HTTP.** Protokolle wie JMS oder Remoting laufen nicht über diesen
  Proxy.

Neue Instanz auf einem eingerichteten Proxy: [neue-instanz.md](neue-instanz.md).
