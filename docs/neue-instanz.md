# Weitere Instanz auf einem eingerichteten Host

Für einen neuen Host von Grund auf: [installation.md](installation.md).
Dort stehen auch Vorabklärung, Firewall/DNS und die JBoss-Umstellung -
sie gelten für jede weitere Instanz genauso.

Meist bedient ein Host eine Instanz. Mehrere Instanzen auf **einer**
Domain bekommen je einen eigenen `LISTEN_PORT` (z. B. `8443`); bei
verschiedenen Domains können alle auf 443 liegen.

```bash
cd /opt/profineo-proxy
cp sites/_beispiel.env.example sites/zweite.env
nano sites/zweite.env          # DOMAIN, BACKEND, ggf. LISTEN_PORT
nano host.env                  # SITES="kunde zweite"
scripts/render.sh              # neue Instanz vorerst nur Port 80
scripts/cert-issue.sh zweite   # neue Domain: Zertifikat holen
scripts/cert-check.sh
```

Liegt die neue Instanz auf derselben Domain wie eine bestehende, gibt es
schon ein Zertifikat - `cert-issue.sh` meldet das und `render.sh` reicht.

Ein anderer `LISTEN_PORT` als 443 braucht eine eigene Weiterleitung in der
Firewall, und das Backend muss diesen Port als externen Port kennen
(interne Anleitung).
