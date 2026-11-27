# Prueft den Caddy-Proxy (Variante D) und schickt bei Problemen eine Mail.
# Gegenstueck zu scripts/cert-check.sh unter Linux.
#
# Ablage: C:\caddy\pruefung.ps1, taeglich als geplante Aufgabe (SYSTEM).
# Von Hand:  powershell -NoProfile -ExecutionPolicy Bypass -File C:\caddy\pruefung.ps1
#
# Nur ASCII in dieser Datei: Windows PowerShell 5.1 liest Skripte ohne BOM
# als ANSI, Umlaute wuerden verstuemmelt.

# ---- Werte anpassen ------------------------------------------------------
$Domain      = 'profi.kunde.at'
$AppPath     = '/profi/'
$WarnTage    = 20
$MailAn      = 'du@example.com'
$MailVon     = 'proxy@example.com'
$SmtpHost    = 'smtp.example.com'
$SmtpPort    = 587
$SmtpUser    = 'proxy@example.com'          # leer = Relay ohne Anmeldung
$SmtpPwDatei = 'C:\caddy\smtp-passwort.txt'
# --------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Log = 'C:\caddy\log\pruefung.log'
$probleme = @()

# 1. Dienst
$dienst = Get-Service caddy -ErrorAction SilentlyContinue
if (-not $dienst -or $dienst.Status -ne 'Running') {
    $probleme += 'Dienst caddy laeuft nicht'
}

# 2. Zertifikat, so wie Caddy es auf 443 ausliefert
try {
    $tcp = [Net.Sockets.TcpClient]::new('127.0.0.1', 443)
    try {
        $annehmen = [Net.Security.RemoteCertificateValidationCallback] { $true }
        $ssl = [Net.Security.SslStream]::new($tcp.GetStream(), $false, $annehmen)
        $ssl.AuthenticateAsClient($Domain)
        $zert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
    } finally {
        $tcp.Close()
    }
    $tage = [int][Math]::Floor(($zert.NotAfter - (Get-Date)).TotalDays)
    if ($tage -lt $WarnTage) {
        $probleme += "Zertifikat laeuft in $tage Tagen ab ($($zert.NotAfter)) - C:\caddy\log\caddy.log lesen"
    }
    if ($zert.Issuer -match 'Caddy Local Authority') {
        $probleme += "Test-Zertifikat aktiv (tls internal im Caddyfile?): $($zert.Issuer)"
    }
    if ($zert.Issuer -match 'STAGING|Fake') {
        $probleme += "Zertifikat aus der Let's-Encrypt-Testumgebung (acme_ca im Caddyfile?): $($zert.Issuer)"
    }
} catch {
    $probleme += "Kein TLS auf Port 443 fuer ${Domain}: $($_.Exception.Message)"
    $tage = '?'
}

# 3. Anwendung hinter dem Proxy
$code = & curl.exe -s -o NUL -m 15 -w '%{http_code}' --resolve "${Domain}:443:127.0.0.1" "https://$Domain$AppPath"
if ($code -notmatch '^[23]') {
    $probleme += "Anwendung antwortet mit '$code' (502/504 = JBoss nicht erreichbar, 000 = keine Verbindung)"
}

# Ergebnis
$zeit = Get-Date -Format 'yyyy-MM-dd HH:mm'
if (-not $probleme) {
    Add-Content $Log "$zeit ok: Zertifikat noch $tage Tage, Anwendung $code"
    exit 0
}

Add-Content $Log "$zeit FEHLER: $($probleme -join ' | ')"
$text = "Server: $env:COMPUTERNAME`r`nDomain: $Domain`r`n`r`n" + ($probleme -join "`r`n")
$mail = @{
    SmtpServer = $SmtpHost
    Port       = $SmtpPort
    From       = $MailVon
    To         = $MailAn
    Subject    = "Proxy ${Domain}: Problem"
    Body       = $text
    Encoding   = [Text.Encoding]::UTF8
}
if ($SmtpUser) {
    $pw = (Get-Content $SmtpPwDatei -Raw).Trim()
    $mail.Credential = [pscredential]::new($SmtpUser, (ConvertTo-SecureString $pw -AsPlainText -Force))
    $mail.UseSsl = $true
}
Send-MailMessage @mail -WarningAction SilentlyContinue
exit 1
