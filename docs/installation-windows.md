# Installation beim Kunden - Windows mit Caddy (Variante D)

> **Stand: noch nicht auf einem Windows-Server getestet.** Vor dem ersten
> Kundeneinsatz einmal in einer Windows-VM durchspielen und diese
> Anleitung dabei korrigieren.

Für Kunden, die nur Windows wollen: [Caddy](https://caddyserver.com) läuft
als Windows-Dienst auf **demselben** Server wie der JBoss, holt das
Let's-Encrypt-Zertifikat selbst und erneuert es selbst. nginx, certbot,
Docker und die Skripte aus `scripts/` werden hier nicht gebraucht.

Linux-Proxy (Varianten A-C): [installation.md](installation.md).
Welche Variante: [varianten.md](varianten.md).

Wie unter Linux ändert bis einschließlich Zertifikat nichts am laufenden
Betrieb - erst Schritt 8 (JBoss umstellen) bringt einen kurzen Ausfall.

Alle Befehle in **PowerShell als Administrator**. In PowerShell ist `curl`
ein anderer Befehl - immer `curl.exe` schreiben.

## 0. Vorab klären

Wie [installation.md](installation.md), Schritt 0 - mit einem Unterschied:
Firewall und DNS zeigen auf den **Windows-Server des JBoss**.

```
Firewall:   <öffentliche IP>:80  -> <Windows-Server>:80    DAUERHAFT offen
            <öffentliche IP>:443 -> <Windows-Server>:443
DNS öffentlich: <domain>  A  <öffentliche IP>
DNS intern:     <domain>  A  <Windows-Server>             (Split-DNS)
```

Windows Server 2019 oder neuer (bringt `curl.exe` mit).

## 1. Sind Port 80 und 443 frei?

```powershell
Get-NetTCPConnection -State Listen -LocalPort 80,443 -ErrorAction SilentlyContinue
```

Keine Ausgabe = frei. Steht dort `OwningProcess` **4**, gehören die Ports
dem Windows-HTTP-Dienst - meist IIS. Mit dem Kunden klären, ob IIS
gebraucht wird; sonst die IIS-Bindung auf Port 80/443 entfernen oder den
Dienst `W3SVC` beenden und deaktivieren.

## 2. Caddy herunterladen

```powershell
mkdir C:\caddy, C:\caddy\log
Invoke-WebRequest "https://caddyserver.com/api/download?os=windows&arch=amd64" -OutFile C:\caddy\caddy.exe
C:\caddy\caddy.exe version
```

Vorlagen aus dem Repo:

```powershell
$r = 'https://raw.githubusercontent.com/AbulSDL/https-proxy/main/windows'
Invoke-WebRequest "$r/Caddyfile.example" -OutFile C:\caddy\Caddyfile
Invoke-WebRequest "$r/pruefung.ps1"      -OutFile C:\caddy\pruefung.ps1
```

## 3. Caddyfile anpassen

```powershell
notepad C:\caddy\Caddyfile
```

Alle `<...>` ersetzen: `email`, Domain, JBoss-Port. Für den ersten Lauf
die Zeile `acme_ca ...staging...` **einkommentieren** (`#` entfernen) - das
ist der Probelauf gegen die Let's-Encrypt-Testumgebung, wie
`cert-issue.sh --trocken`.

Notepad speichert gern `Caddyfile.txt`: beim Speichern "Alle Dateien"
wählen.

```powershell
C:\caddy\caddy.exe validate --config C:\caddy\Caddyfile    # "Valid configuration"
```

**Erreicht Caddy den JBoss?**

```powershell
curl.exe -s -o NUL -m 5 -w "%{http_code}`n" http://127.0.0.1:28080/profi/
```

Erwartet: `200` oder eine Weiterleitung wie `302`. Bei `000` erst klären,
auf welcher Adresse der JBoss lauscht (`netstat -ano | findstr :28080`).

## 4. Windows-Firewall

```powershell
New-NetFirewallRule -DisplayName "Caddy HTTP/HTTPS" -Direction Inbound `
    -Protocol TCP -LocalPort 80,443 -Action Allow
```

Der JBoss-Port braucht **keine** Freigabe: Caddy spricht ihn über
`127.0.0.1` an. Empfehlung: den JBoss nur an `127.0.0.1` binden.

## 5. Caddy als Dienst

```powershell
sc.exe create caddy start= auto binPath= "C:\caddy\caddy.exe run --config C:\caddy\Caddyfile"
sc.exe failure caddy reset= 86400 actions= restart/5000/restart/5000/restart/60000
sc.exe start caddy
sc.exe query caddy                       # STATE: RUNNING
```

Die Leerzeichen nach `start=`, `binPath=` usw. sind Pflicht. `failure`
startet Caddy nach einem Absturz neu (wie `restart: unless-stopped`).

Der Dienst holt jetzt das (Test-)Zertifikat:

```powershell
Get-Content C:\caddy\log\caddy.log -Tail 20 -Wait     # Strg+C beendet
```

Erwartet: `certificate obtained successfully`. Bei `Timeout during
connect` oder `connection refused` ist Port 80 von außen nicht erreichbar
(Schritt 0). Caddy versucht es selbst weiter - nach der Korrektur einfach
warten.

**Echtes Zertifikat:** `acme_ca`-Zeile wieder auskommentieren, dann

```powershell
C:\caddy\caddy.exe reload --config C:\caddy\Caddyfile
Get-Content C:\caddy\log\caddy.log -Tail 20
```

Prüfen:

```powershell
curl.exe -sI https://profi.kunde.at/profi/ --resolve profi.kunde.at:443:127.0.0.1
```

Ohne `-k` - das gelingt nur mit einem gültigen Let's-Encrypt-Zertifikat.

Die Zertifikate liegen unter
`C:\Windows\System32\config\systemprofile\AppData\Roaming\Caddy`
(gehört in die Datensicherung; fehlt der Ordner, holt Caddy sie neu).

## 6. Prüfung und Fehlermail

```powershell
notepad C:\caddy\pruefung.ps1          # Werte oben im Skript anpassen
```

SMTP-Passwort ablegen, lesbar nur für SYSTEM und Administratoren
(entfällt bei einem Relay ohne Anmeldung, dann `$SmtpUser = ''`):

```powershell
Set-Content C:\caddy\smtp-passwort.txt 'GEHEIM'
icacls C:\caddy\smtp-passwort.txt /inheritance:r /grant:r "*S-1-5-18:R" "*S-1-5-32-544:R"
```

Von Hand testen:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\caddy\pruefung.ps1
Get-Content C:\caddy\log\pruefung.log -Tail 3      # "ok: Zertifikat noch .. Tage"
```

Mail testen: in `pruefung.ps1` vorübergehend `$WarnTage = 999` setzen,
Skript starten - die Mail muss ankommen. Danach zurück auf `20`.

Täglich um 08:00 als geplante Aufgabe:

```powershell
$a = New-ScheduledTaskAction -Execute powershell.exe `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\caddy\pruefung.ps1'
$t = New-ScheduledTaskTrigger -Daily -At 08:00
Register-ScheduledTask -TaskName 'Caddy-Pruefung' -Action $a -Trigger $t `
    -User 'SYSTEM' -RunLevel Highest
Start-ScheduledTask 'Caddy-Pruefung'
Get-Content C:\caddy\log\pruefung.log -Tail 1
```

## 7. Neustart testen

Server (oder nur den Dienst) neu starten, dann:

```powershell
sc.exe query caddy                     # RUNNING
curl.exe -s -o NUL -w "%{http_code}`n" https://profi.kunde.at/profi/ --resolve profi.kunde.at:443:127.0.0.1
```

## 8. JBoss umstellen (angekündigter Ausfall)

Genau wie unter Linux - nach der **internen Anleitung**:
[installation.md](installation.md), Schritt 8. Caddy gibt `Host`,
`X-Forwarded-Proto: https` und `X-Forwarded-For` von selbst weiter.

Abschlusstest: `https://profi.kunde.at/profi/` im Browser, anmelden,
mehrmals klicken.

## 9. Optional: HSTS

Erst wenn der Rückweg auf HTTP nicht mehr gebraucht wird: im Caddyfile die
Zeile `header Strict-Transport-Security ...` einkommentieren, dann
`caddy reload` wie oben.

## Später

**Caddyfile geändert:** `C:\caddy\caddy.exe reload --config C:\caddy\Caddyfile`
(ohne Unterbrechung).

**Caddy aktualisieren:**

```powershell
sc.exe stop caddy
Invoke-WebRequest "https://caddyserver.com/api/download?os=windows&arch=amd64" -OutFile C:\caddy\caddy.exe
sc.exe start caddy
```

## Unterschiede zu Linux

- HTTP leitet mit Code `308` auf HTTPS um (Linux: `301`) - für Browser
  gleich.
- Caddy erneuert das Zertifikat selbst, etwa 30 Tage vor Ablauf; es gibt
  keine Timer. Scheitert das, steht es in `caddy.log`, und `pruefung.ps1`
  meldet es ab 20 Tagen vor Ablauf per Mail.
- Kann Caddy bei Let's Encrypt nichts holen, weicht es von selbst auf den
  Anbieter ZeroSSL aus. Das Zertifikat ist dann genauso gültig.

## Wenn etwas nicht geht

| Meldung | Ursache |
|---|---|
| Dienst startet nicht | `C:\caddy\log\caddy.log` lesen; `caddy validate` wie in Schritt 3 |
| `bind: An attempt was made to access a socket ...` | Port 80/443 belegt - Schritt 1 |
| `Timeout during connect` in `caddy.log` | Port 80 nicht von außen auf den Server weitergeleitet |
| `Anwendung antwortet mit '502'` | JBoss läuft nicht oder anderer Port im Caddyfile |
| Anmeldung geht, erster Klick führt ins Leere | JBoss noch nicht umgestellt (Schritt 8) |
| Mail kommt nicht | `C:\caddy\log\pruefung.log`; SMTP-Werte im Skript, Passwortdatei |
