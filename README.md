Done. I packaged the complete installer project into a ZIP.

Download Rabby AI Gateway — Full Installer ZIP⁠￼

It includes:

* OpenClaw
* Ollama
* Docker CE + Compose
* PostgreSQL
* Redis
* n8n
* Cockpit
* Tailscale
* UFW + Fail2ban
* systemd services
* persistent data directories
* automatic generated credentials
* health-check command
* backup command
* WhatsApp setup
* Telegram setup
* Discord setup
* management CLI: rabby
* ARM64/amd64-oriented Debian setup
* localhost binding for sensitive services
* README + installation instructions

Install:

unzip rabby-ai-gateway.zip
cd rabby-ai-gateway
sudo bash install.sh

Then:

rabby-health

and:

rabby status

Credentials are automatically generated and stored in:

/opt/rabby-ai/INSTALLATION.txt
