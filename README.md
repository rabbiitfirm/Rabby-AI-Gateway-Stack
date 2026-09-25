Yes. Below is a single-pass Debian installer. It uses the current official installation paths for OpenClaw and Ollama, Docker’s official Debian repository, and keeps PostgreSQL/Redis/n8n/OpenClaw bound to localhost by default. Docker explicitly warns that published container ports can bypass UFW, so this matters for the firewall design. 

It installs the infrastructure and prepares WhatsApp, Telegram, and Discord; those channels still require your own account/bot credentials or WhatsApp QR pairing, which cannot legitimately be automated without your credentials. OpenClaw currently documents all three channel setup flows. 

One command

Save this as install.sh:

#!/usr/bin/env bash
set -Eeuo pipefail
# ============================================================
# RABBY AI GATEWAY - ALL-IN-ONE DEBIAN INSTALLER
# ============================================================
#
# Installs:
#   OpenClaw
#   Ollama
#   Docker Engine
#   Docker Compose
#   PostgreSQL
#   Redis
#   n8n
#   Cockpit Admin Dashboard
#   Tailscale
#   UFW
#   Fail2ban
#   systemd services
#
# Prepares:
#   WhatsApp
#   Telegram
#   Discord
#
# Target:
#   Debian 12 / Debian 13
#   amd64 / arm64 / armhf where supported
#
# ============================================================
set +H
APP_DIR="/opt/rabby-ai"
DATA_DIR="$APP_DIR/data"
COMPOSE_DIR="$APP_DIR/docker"
BACKUP_DIR="$APP_DIR/backups"
OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/home/$OPENCLAW_USER"
OPENCLAW_PORT=18789
OLLAMA_PORT=11434
N8N_PORT=5678
POSTGRES_PORT=5432
REDIS_PORT=6379
COCKPIT_PORT=9090
export DEBIAN_FRONTEND=noninteractive
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
log() {
    echo -e "${GREEN}[RABBY]${NC} $*"
}
warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}
die() {
    echo -e "${RED}[ERROR]${NC} $*"
    exit 1
}
trap 'die "Installation failed at line $LINENO."' ERR
# ------------------------------------------------------------
# ROOT
# ------------------------------------------------------------
[[ "$EUID" -eq 0 ]] || die "Run with sudo/root."
# ------------------------------------------------------------
# OS
# ------------------------------------------------------------
[[ -f /etc/os-release ]] || die "Cannot detect Linux."
source /etc/os-release
if [[ "$ID" != "debian" ]]; then
    warn "This installer is designed for Debian."
    warn "Detected: $PRETTY_NAME"
fi
ARCH="$(dpkg --print-architecture)"
log "OS: $PRETTY_NAME"
log "Architecture: $ARCH"
# ------------------------------------------------------------
# BASIC PACKAGES
# ------------------------------------------------------------
log "Installing base packages..."
apt-get update
apt-get install -y \
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    git \
    jq \
    unzip \
    zip \
    tar \
    rsync \
    openssl \
    nano \
    vim \
    htop \
    tree \
    tmux \
    net-tools \
    dnsutils \
    iproute2 \
    procps \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    ufw \
    fail2ban \
    sudo
# ------------------------------------------------------------
# TIMEZONE
# ------------------------------------------------------------
timedatectl set-timezone Asia/Dhaka 2>/dev/null || true
# ------------------------------------------------------------
# DIRECTORIES
# ------------------------------------------------------------
log "Creating Rabby directories..."
mkdir -p \
    "$APP_DIR" \
    "$DATA_DIR" \
    "$COMPOSE_DIR" \
    "$BACKUP_DIR"
mkdir -p \
    "$DATA_DIR/postgres" \
    "$DATA_DIR/redis" \
    "$DATA_DIR/n8n" \
    "$DATA_DIR/ollama" \
    "$DATA_DIR/openclaw" \
    "$DATA_DIR/uploads"
# ------------------------------------------------------------
# OPENCLAW USER
# ------------------------------------------------------------
if ! id "$OPENCLAW_USER" >/dev/null 2>&1; then
    useradd \
        --create-home \
        --shell /bin/bash \
        "$OPENCLAW_USER"
fi
mkdir -p "$OPENCLAW_HOME/.openclaw"
chown -R \
    "$OPENCLAW_USER:$OPENCLAW_USER" \
    "$OPENCLAW_HOME"
# ------------------------------------------------------------
# DOCKER OFFICIAL REPOSITORY
# ------------------------------------------------------------
log "Installing Docker Engine..."
install -m 0755 -d /etc/apt/keyrings
curl \
    --fail \
    --silent \
    --show-error \
    --location \
    https://download.docker.com/linux/debian/gpg \
    --output /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
systemctl enable --now docker
usermod -aG docker "$OPENCLAW_USER"
# ------------------------------------------------------------
# DOCKER NETWORK
# ------------------------------------------------------------
docker network inspect rabby_internal >/dev/null 2>&1 || \
    docker network create rabby_internal
# ------------------------------------------------------------
# DATABASE SECRETS
# ------------------------------------------------------------
POSTGRES_DB="rabby"
POSTGRES_USER="rabby"
POSTGRES_PASSWORD="$(openssl rand -hex 32)"
REDIS_PASSWORD="$(openssl rand -hex 32)"
N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)"
OPENCLAW_TOKEN="$(openssl rand -hex 32)"
# ------------------------------------------------------------
# DOCKER COMPOSE
# ------------------------------------------------------------
log "Creating PostgreSQL / Redis / n8n stack..."
cat >"$COMPOSE_DIR/docker-compose.yml" <<EOF
services:
  postgres:
    image: postgres:16-alpine
    container_name: rabby-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ${DATA_DIR}/postgres:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:${POSTGRES_PORT}:5432"
    healthcheck:
      test:
        - CMD-SHELL
        - pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - rabby_internal
  redis:
    image: redis:7-alpine
    container_name: rabby-redis
    restart: unless-stopped
    command:
      - redis-server
      - --appendonly
      - "yes"
      - --requirepass
      - ${REDIS_PASSWORD}
    volumes:
      - ${DATA_DIR}/redis:/data
    ports:
      - "127.0.0.1:${REDIS_PORT}:6379"
    healthcheck:
      test:
        - CMD
        - redis-cli
        - -a
        - ${REDIS_PASSWORD}
        - ping
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - rabby_internal
  n8n:
    image: n8nio/n8n:latest
    container_name: rabby-n8n
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_HOST: 127.0.0.1
      N8N_PORT: 5678
      N8N_PROTOCOL: http
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_SECURE_COOKIE: "false"
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE: "168"
      GENERIC_TIMEZONE: Asia/Dhaka
      TZ: Asia/Dhaka
    ports:
      - "127.0.0.1:${N8N_PORT}:5678"
    volumes:
      - ${DATA_DIR}/n8n:/home/node/.n8n
    networks:
      - rabby_internal
networks:
  rabby_internal:
    external: true
EOF
cat >"$COMPOSE_DIR/.env" <<EOF
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
OPENCLAW_TOKEN=${OPENCLAW_TOKEN}
EOF
chmod 600 "$COMPOSE_DIR/.env"
# ------------------------------------------------------------
# START DOCKER STACK
# ------------------------------------------------------------
cd "$COMPOSE_DIR"
docker compose pull
docker compose up -d
# ------------------------------------------------------------
# OLLAMA
# ------------------------------------------------------------
log "Installing Ollama..."
if ! command -v ollama >/dev/null 2>&1; then
    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        https://ollama.com/install.sh \
        | sh
fi
systemctl enable --now ollama || true
mkdir -p /etc/systemd/system/ollama.service.d
cat >/etc/systemd/system/ollama.service.d/rabby.conf <<EOF
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_KEEP_ALIVE=10m"
EOF
systemctl daemon-reload
systemctl restart ollama || true
# ------------------------------------------------------------
# OPENCLAW
# ------------------------------------------------------------
log "Installing OpenClaw..."
sudo -iu "$OPENCLAW_USER" bash -lc \
    'curl -fsSL --proto "=https" --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-onboard'
OPENCLAW_BIN="$(
    sudo -iu "$OPENCLAW_USER" bash -lc \
    'command -v openclaw || true'
)"
if [[ -z "$OPENCLAW_BIN" ]]; then
    OPENCLAW_BIN="$(command -v openclaw || true)"
fi
if [[ -z "$OPENCLAW_BIN" ]]; then
    die "OpenClaw installation completed but binary was not found."
fi
log "OpenClaw: $OPENCLAW_BIN"
# ------------------------------------------------------------
# OPENCLAW STORAGE
# ------------------------------------------------------------
mkdir -p \
    "$OPENCLAW_HOME/.openclaw/workspace" \
    "$OPENCLAW_HOME/.openclaw/credentials" \
    "$OPENCLAW_HOME/.openclaw/logs"
# ------------------------------------------------------------
# OPENCLAW CONFIG
# ------------------------------------------------------------
cat >"$OPENCLAW_HOME/.openclaw/openclaw.json" <<EOF
{
  "gateway": {
    "mode": "local",
    "port": ${OPENCLAW_PORT},
    "bind": "loopback",
    "auth": {
      "mode": "token",
      "token": "${OPENCLAW_TOKEN}"
    }
  },
  "agents": {
    "defaults": {
      "workspace": "${OPENCLAW_HOME}/.openclaw/workspace"
    }
  },
  "channels": {
    "whatsapp": {
      "allowFrom": []
    }
  }
}
EOF
chown -R \
    "$OPENCLAW_USER:$OPENCLAW_USER" \
    "$OPENCLAW_HOME/.openclaw"
chmod 700 "$OPENCLAW_HOME/.openclaw"
chmod 600 "$OPENCLAW_HOME/.openclaw/openclaw.json"
# ------------------------------------------------------------
# OPENCLAW SYSTEMD
# ------------------------------------------------------------
log "Installing OpenClaw systemd service..."
cat >/etc/systemd/system/rabby-openclaw.service <<EOF
[Unit]
Description=Rabby OpenClaw AI Gateway
After=network-online.target docker.service ollama.service
Wants=network-online.target
[Service]
Type=simple
User=${OPENCLAW_USER}
Group=${OPENCLAW_USER}
Environment=HOME=${OPENCLAW_HOME}
Environment=PATH=/usr/local/bin:/usr/bin:/bin:${OPENCLAW_HOME}/.local/bin
WorkingDirectory=${OPENCLAW_HOME}
ExecStart=${OPENCLAW_BIN} gateway --port ${OPENCLAW_PORT}
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable rabby-openclaw.service
systemctl restart rabby-openclaw.service || true
# ------------------------------------------------------------
# COCKPIT ADMIN DASHBOARD
# ------------------------------------------------------------
log "Installing Cockpit..."
apt-get install -y \
    cockpit \
    cockpit-networkmanager \
    cockpit-packagekit
systemctl enable --now cockpit.socket
# ------------------------------------------------------------
# TAILSCALE
# ------------------------------------------------------------
log "Installing Tailscale..."
if ! command -v tailscale >/dev/null 2>&1; then
    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        https://tailscale.com/install.sh \
        | sh
fi
systemctl enable --now tailscaled || true
# ------------------------------------------------------------
# FIREWALL
# ------------------------------------------------------------
log "Configuring firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
# SSH
ufw allow 22/tcp comment "SSH"
# Tailscale interface
ufw allow in on tailscale0 2>/dev/null || true
ufw --force enable
# ------------------------------------------------------------
# FAIL2BAN
# ------------------------------------------------------------
systemctl enable --now fail2ban
# ------------------------------------------------------------
# RABBY MANAGEMENT COMMAND
# ------------------------------------------------------------
cat >/usr/local/bin/rabby <<'EOF'
#!/usr/bin/env bash
set -e
case "${1:-}" in
status)
    echo "===== RABBY AI ====="
    echo
    echo "OpenClaw:"
    systemctl --no-pager status rabby-openclaw.service || true
    echo
    echo "Ollama:"
    systemctl --no-pager status ollama.service || true
    echo
    echo "Docker:"
    systemctl --no-pager status docker.service || true
    echo
    echo "Containers:"
    docker ps
    ;;
logs)
    journalctl \
        -u rabby-openclaw.service \
        -f
    ;;
restart)
    systemctl restart rabby-openclaw.service || true
    systemctl restart ollama.service || true
    docker compose \
        -f /opt/rabby-ai/docker/docker-compose.yml \
        restart
    ;;
start)
    systemctl start rabby-openclaw.service || true
    systemctl start ollama.service || true
    docker compose \
        -f /opt/rabby-ai/docker/docker-compose.yml \
        start
    ;;
stop)
    systemctl stop rabby-openclaw.service || true
    docker compose \
        -f /opt/rabby-ai/docker/docker-compose.yml \
        stop
    ;;
channels)
    sudo -iu openclaw \
        openclaw channels status
    ;;
whatsapp)
    sudo -iu openclaw \
        openclaw channels login
    ;;
telegram)
    echo
    echo "Run:"
    echo
    echo 'sudo -iu openclaw openclaw channels add --channel telegram --token "YOUR_BOT_TOKEN"'
    ;;
discord)
    echo
    echo "Run:"
    echo
    echo 'sudo -iu openclaw openclaw channels add --channel discord --token "YOUR_BOT_TOKEN"'
    ;;
dashboard)
    sudo -iu openclaw \
        openclaw dashboard \
        --no-open
    ;;
doctor)
    sudo -iu openclaw \
        openclaw doctor
    ;;
backup)
    DATE="$(date +%Y%m%d-%H%M%S)"
    DEST="/opt/rabby-ai/backups/$DATE"
    mkdir -p "$DEST"
    docker exec \
        rabby-postgres \
        pg_dump \
        -U rabby \
        rabby \
        >"$DEST/postgres.sql"
    tar \
        -czf "$DEST/openclaw.tar.gz" \
        /home/openclaw/.openclaw
    echo "Backup:"
    echo "$DEST"
    ;;
update)
    docker compose \
        -f /opt/rabby-ai/docker/docker-compose.yml \
        pull
    docker compose \
        -f /opt/rabby-ai/docker/docker-compose.yml \
        up -d
    curl \
        -fsSL \
        https://ollama.com/install.sh \
        | sh
    sudo -iu openclaw \
        openclaw update \
        || true
    ;;
*)
    echo
    echo "RABBY AI MANAGEMENT"
    echo
    echo "rabby status"
    echo "rabby logs"
    echo "rabby restart"
    echo "rabby start"
    echo "rabby stop"
    echo "rabby channels"
    echo "rabby whatsapp"
    echo "rabby telegram"
    echo "rabby discord"
    echo "rabby dashboard"
    echo "rabby doctor"
    echo "rabby backup"
    echo "rabby update"
    echo
    ;;
esac
EOF
chmod +x /usr/local/bin/rabby
# ------------------------------------------------------------
# HEALTH CHECK
# ------------------------------------------------------------
cat >/usr/local/bin/rabby-health <<'EOF'
#!/usr/bin/env bash
echo
echo "=========================================="
echo "       RABBY AI GATEWAY HEALTH"
echo "=========================================="
echo
printf "Docker:   "
systemctl is-active docker || true
printf "Ollama:   "
systemctl is-active ollama || true
printf "OpenClaw: "
systemctl is-active rabby-openclaw || true
echo
echo "Containers:"
docker ps \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo
echo "Listening services:"
ss -lntp |
    grep -E '18789|11434|5678|5432|6379|9090' \
    || true
echo
echo "Memory:"
free -h
echo
echo "Disk:"
df -h /
echo
echo "Tailscale:"
tailscale status 2>/dev/null || true
echo
EOF
chmod +x /usr/local/bin/rabby-health
# ------------------------------------------------------------
# INSTALLATION INFO
# ------------------------------------------------------------
cat >"$APP_DIR/INSTALLATION.txt" <<EOF
===========================================================
RABBY AI GATEWAY
===========================================================
OpenClaw
--------
127.0.0.1:${OPENCLAW_PORT}
Ollama
------
127.0.0.1:${OLLAMA_PORT}
n8n
--
127.0.0.1:${N8N_PORT}
PostgreSQL
----------
127.0.0.1:${POSTGRES_PORT}
Redis
-----
127.0.0.1:${REDIS_PORT}
Cockpit
-------
https://SERVER-IP:${COCKPIT_PORT}
DATABASE
========
Database:
${POSTGRES_DB}
User:
${POSTGRES_USER}
Password:
${POSTGRES_PASSWORD}
REDIS PASSWORD
==============
${REDIS_PASSWORD}
N8N ENCRYPTION KEY
==================
${N8N_ENCRYPTION_KEY}
OPENCLAW GATEWAY TOKEN
======================
${OPENCLAW_TOKEN}
MANAGEMENT
==========
rabby status
rabby logs
rabby restart
rabby start
rabby stop
rabby channels
rabby whatsapp
rabby telegram
rabby discord
rabby dashboard
rabby doctor
rabby backup
rabby update
Health:
rabby-health
CHANNELS
========
WhatsApp:
rabby whatsapp
Telegram:
rabby telegram
Discord:
rabby discord
REMOTE ACCESS
=============
tailscale up
IMPORTANT
=========
This file contains secrets.
Do not publish it.
PostgreSQL, Redis, n8n, Ollama and
OpenClaw are localhost-bound by default.
Use Tailscale or an HTTPS reverse proxy
for remote access.
EOF
chmod 600 "$APP_DIR/INSTALLATION.txt"
# ------------------------------------------------------------
# FINAL TESTS
# ------------------------------------------------------------
log "Running final checks..."
sleep 5
docker ps
echo
systemctl is-active docker || true
systemctl is-active ollama || true
systemctl is-active rabby-openclaw || true
# ------------------------------------------------------------
# FINISH
# ------------------------------------------------------------
echo
echo "============================================================"
echo "             RABBY AI GATEWAY INSTALLED"
echo "============================================================"
echo
echo "Health:"
echo "  rabby-health"
echo
echo "Status:"
echo "  rabby status"
echo
echo "Dashboard:"
echo "  http://127.0.0.1:${OPENCLAW_PORT}/"
echo
echo "n8n:"
echo "  http://127.0.0.1:${N8N_PORT}/"
echo
echo "Cockpit:"
echo "  https://SERVER-IP:${COCKPIT_PORT}/"
echo
echo "WhatsApp:"
echo "  rabby whatsapp"
echo
echo "Telegram:"
echo "  rabby telegram"
echo
echo "Discord:"
echo "  rabby discord"
echo
echo "Credentials:"
echo "  ${APP_DIR}/INSTALLATION.txt"
echo
echo "============================================================"

Run it

nano install.sh

Paste the script, save, then:

chmod +x install.sh
sudo ./install.sh

Or from an existing file:

sudo bash install.sh

After installation

rabby-health

Then configure the channels:

rabby whatsapp

For Telegram:

sudo -iu openclaw openclaw channels add \
  --channel telegram \
  --token "YOUR_TELEGRAM_BOT_TOKEN"

For Discord:

sudo -iu openclaw openclaw channels add \
  --channel discord \
  --token "YOUR_DISCORD_BOT_TOKEN"

OpenClaw’s current documentation confirms its Linux installer, systemd support, Control UI, and channel support for WhatsApp, Telegram and Discord. 

For local AI, after installation you can install a model with:

ollama pull qwen3:4b

or, on a stronger machine:

ollama pull qwen3:8b

The official Ollama Linux installer is currently curl -fsSL https://ollama.com/install.sh | sh. 

One security point: don’t expose ports 5432, 6379, 5678, 11434, or 18789 directly to the public Internet. Docker specifically documents that published container ports can bypass UFW rules; the script therefore binds those services to 127.0.0.1. 

If you want zero-touch remote access, run tailscale up after installation and administer the stack through the private Tailscale network.
