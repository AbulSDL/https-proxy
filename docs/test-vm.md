# Testlauf in einer VM

Den ganzen Ablauf aus [installation.md](installation.md) einmal ohne Kunden
durchspielen - z. B. in einer Debian-VM auf dem eigenen Rechner (UTM,
VirtualBox, Hyper-V). Getestet wird alles außer dem echten
Let's-Encrypt-Zertifikat: Let's Encrypt erreicht die VM aus dem Internet
nicht, darum ersetzt ein selbst ausgestelltes Zertifikat Schritt 7.

Statt JBoss antwortet ein kleiner Python-Webserver. Alles als root
(`sudo su -` oder `sudo -i`).

## 1. Software

[installation.md](installation.md), Schritt 1, genau so - damit wird die
Anleitung gleich mitgetestet. Zusätzlich für das Test-Backend:

```bash
apt install -y python3
docker run --rm hello-world     # muss "Hello from Docker!" zeigen
```

Schritt 2 (msmtp) nur, wenn SMTP-Zugangsdaten zur Hand sind. Ohne warnt
`install.sh` nur.

## 2. Repo und Testwerte

```bash
git clone https://github.com/AbulSDL/https-proxy.git /opt/profineo-proxy
cd /opt/profineo-proxy
cp host.env.example host.env
sed -i 's/^SITES=.*/SITES=test/' host.env
printf 'DOMAIN=profi.test.local\nBACKEND=127.0.0.1:28080\n' > sites/test.env
nano host.env                   # ACME_EMAIL, MAIL_AN: eigene Adresse
```

## 3. Test-Backend statt JBoss

```bash
mkdir -p /tmp/be/profi && echo hallo > /tmp/be/profi/index.html
(cd /tmp/be && nohup python3 -m http.server 28080 >/dev/null 2>&1 &)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:28080/profi/   # 200
```

Nach einem Neustart der VM ist das Backend weg - die Zeile mit `nohup`
erneut ausführen.

## 4. nginx und Timer

```bash
scripts/render.sh       # Warnung "kein Zertifikat" ist normal, endet mit "nginx gestartet"
docker ps               # profineo-proxy: Up
scripts/install.sh      # am Ende beide profineo-Timer gelistet
```

## 5. Platzhalter-Zertifikat

```bash
d=profi.test.local; mkdir -p letsencrypt/live/$d
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
  -subj "/CN=$d" -addext "subjectAltName=DNS:$d" \
  -keyout letsencrypt/live/$d/privkey.pem -out letsencrypt/live/$d/fullchain.pem
scripts/render.sh       # "test: https://profi.test.local:443/profi/ -> ..." und "nginx neu geladen"
```

## 6. Prüfen

```bash
curl -k --resolve $d:443:127.0.0.1 https://$d/profi/                              # hallo
curl -sI --resolve $d:80:127.0.0.1 http://$d/profi/ | head -1                     # 301
curl -sk --resolve $d:443:127.0.0.1 -o /dev/null -w '%{http_code}\n' https://$d/  # 404
scripts/cert-check.sh   # ok, dazu "NICHT von certbot" - im Test richtig
```

Backend-Ausfall: Test-Backend stoppen, dann muss der Proxy `502` liefern:

```bash
pkill -f 'http.server 28080'
curl -sk --resolve $d:443:127.0.0.1 -o /dev/null -w '%{http_code}\n' https://$d/profi/  # 502
(cd /tmp/be && nohup python3 -m http.server 28080 >/dev/null 2>&1 &)
```

## 7. Geänderte nginx.conf (wie nach `git pull`)

```bash
echo '# test' >> nginx/nginx.conf && scripts/render.sh   # "Container neu erstellt"
git checkout nginx/nginx.conf && scripts/render.sh
```

## 8. Optional: im Browser vom eigenen Rechner

IP der VM mit `ip -4 a` ermitteln, auf dem eigenen Rechner in `/etc/hosts`
(Windows: `C:\Windows\System32\drivers\etc\hosts`) eintragen:

```
<VM-IP>  profi.test.local
```

Dann `https://profi.test.local/profi/` öffnen und die Zertifikatswarnung
bestätigen.

## Was in der VM fehlschlagen muss

- `scripts/cert-issue.sh test --trocken` endet mit einem Timeout - Let's
  Encrypt erreicht die VM nicht.
- `renew.sh` meldet zweimal täglich, dass die Instanz kein
  certbot-Zertifikat hat, und schickt eine Fehlermail, falls msmtp
  eingerichtet ist.

## Aufräumen

```bash
cd /opt/profineo-proxy && docker compose down
systemctl disable --now profineo-renew.timer profineo-check.timer
pkill -f 'http.server 28080'
```

Oder einfach die VM verwerfen.
