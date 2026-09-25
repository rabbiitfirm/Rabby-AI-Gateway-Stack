cat > /root/install-rabby-ai.sh <<'RABBY_INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# RABBY AI GATEWAY
# Complete Debian self-hosted AI automation stack
#
# Components:
#   OpenClaw
#   Ollama
#   Docker CE + Compose
#   n8n
#   PostgreSQL
#   Redis
#   Cockpit
#   Tailscale
#   UFW
#   systemd
#   WhatsApp / Telegram / Discord channel preparation
#
# Tested design target:
#   Debian 12 / Debian 13
#   amd64 / arm64
###############################################################################

APP_NAME="rabby-ai"
APP_DIR="/opt/rabby-ai"
DATA_DIR="${APP_DIR}/data"
COMPOSE_DIR="${APP_DIR}/docker"
BACKUP_DIR="${APP_DIR}/backups"
LOG_DIR="/var/log/rabby-ai"

OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/home/${OPENCLAW_USER}"

N8N_PORT="5678"
POSTGRES_PORT="5432"
REDIS_PORT="6379"
OPENCLAW_PORT="18789"
COCKPIT_PORT="9090"

POSTGRES_DB="rabby"
POSTGRES_USER="rabby"
POSTGRES_PASSWORD="$(openssl rand -hex 32)"
REDIS_PASSWORD="$(openssl rand -hex 32)"

N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)"
OPENCLAW_TOKEN="$(openssl rand -hex 32)"

export DEBIAN_FRONTEND=noninteractive

###############################################################################
# COLORS
###############################################################################

RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BLUE="$(printf '\033[34m')"
CYAN="$(printf '\033[36m')"
RESET="$(printf '\033[0m')"

log() {
    echo -e "${GREEN}[RABBY]${RESET} $*"
}

info() {
    echo -e "${CYAN}[INFO]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

fail() {
    echo -e "${RED}[ERROR]${RESET} $*"
    exit 1
}

###############################################################################
# ERROR HANDLING
###############################################################################

trap 'echo -e "${RED}[ERROR] Installation failed at line ${LINENO}.${RESET}"' ERR

###############################################################################
# ROOT CHECK
###############################################################################

if [[ "${EUID}" -ne 0 ]]; then
    fail "Run this installer as root: sudo bash /root/install-rabby-ai.sh"
fi

###############################################################################
# OS CHECK
###############################################################################

if [[ ! -f /etc/os-release ]]; then
    fail "Cannot identify operating system."
fi

source /etc/os-release

if [[ "${ID}" != "debian" ]]; then
    warn "This installer targets Debian. Detected: ${ID}"
    read -r -p "Continue anyway? [y/N]: " ANSWER
    [[ "${ANSWER}" =~ ^[Yy]$ ]] || exit 1
fi

ARCH="$(dpkg --print-architecture)"

log "Operating system: ${PRETTY_NAME}"
log "Architecture: ${ARCH}"

###############################################################################
# CPU / MEMORY INFORMATION
###############################################################################

CPU_CORES="$(nproc)"
RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"

info "CPU cores: ${CPU_CORES}"
info "RAM: ${RAM_MB} MB"

if (( RAM_MB < 2048 )); then
    warn "Less than 2GB RAM detected."
    warn "Ollama/local models may be extremely slow or unusable."
fi

###############################################################################
# UPDATE SYSTEM
###############################################################################

log "Updating Debian..."

apt-get update
apt-get upgrade -y

###############################################################################
# BASIC PACKAGES
###############################################################################

log "Installing base packages..."

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
    screen \
    net-tools \
    dnsutils \
    iproute2 \
    procps \
    pciutils \
    usbutils \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    ufw \
    fail2ban \
    ca-certificates

###############################################################################
# TIMEZONE
###############################################################################

if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Asia/Dhaka || true
fi

###############################################################################
# CREATE APPLICATION DIRECTORIES
###############################################################################

log "Creating application directories..."

mkdir -p \
    "${APP_DIR}" \
    "${DATA_DIR}" \
    "${COMPOSE_DIR}" \
    "${BACKUP_DIR}" \
    "${LOG_DIR}"

mkdir -p \
    "${DATA_DIR}/postgres" \
    "${DATA_DIR}/redis" \
    "${DATA_DIR}/n8n" \
    "${DATA_DIR}/ollama" \
    "${DATA_DIR}/openclaw" \
    "${DATA_DIR}/uploads"

###############################################################################
# CREATE OPENCLAW USER
###############################################################################

if ! id "${OPENCLAW_USER}" >/dev/null 2>&1; then
    log "Creating OpenClaw system user..."

    useradd \
        --create-home \
        --shell /bin/bash \
        "${OPENCLAW_USER}"
fi

mkdir -p "${OPENCLAW_HOME}/.openclaw"

chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" \
    "${OPENCLAW_HOME}" \
    "${DATA_DIR}/openclaw"

###############################################################################
# DOCKER OFFICIAL REPOSITORY
###############################################################################

log "Installing Docker Engine..."

install -m 0755 -d /etc/apt/keyrings

if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL \
        https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc
fi

cat > /etc/apt/sources.list.d/docker.sources <<EOF
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

###############################################################################
# DOCKER GROUP
###############################################################################

usermod -aG docker "${OPENCLAW_USER}" || true

###############################################################################
# DOCKER NETWORK
###############################################################################

docker network inspect rabby_internal >/dev/null 2>&1 || \
    docker network create rabby_internal

###############################################################################
# DOCKER COMPOSE
###############################################################################

log "Creating PostgreSQL + Redis + n8n stack..."

cat > "${COMPOSE_DIR}/docker-compose.yml" <<EOF
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
      - yes
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

###############################################################################
# ENVIRONMENT FILE
###############################################################################

cat > "${COMPOSE_DIR}/.env" <<EOF
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

REDIS_PASSWORD=${REDIS_PASSWORD}

N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

OPENCLAW_TOKEN=${OPENCLAW_TOKEN}
EOF

chmod 600 "${COMPOSE_DIR}/.env"

###############################################################################
# START DOCKER SERVICES
###############################################################################

log "Starting PostgreSQL, Redis and n8n..."

cd "${COMPOSE_DIR}"

docker compose pull
docker compose up -d

###############################################################################
# OLLAMA
###############################################################################

log "Installing Ollama..."

if ! command -v ollama >/dev/null 2>&1; then
    curl -fsSL https://ollama.com/install.sh | sh
fi

systemctl enable --now ollama || true

###############################################################################
# OLLAMA CONFIG
###############################################################################

mkdir -p /etc/systemd/system/ollama.service.d

cat > /etc/systemd/system/ollama.service.d/rabby.conf <<EOF
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_KEEP_ALIVE=10m"
EOF

systemctl daemon-reload
systemctl restart ollama || true

###############################################################################
# OPENCLAW
###############################################################################

log "Installing OpenClaw..."

if ! command -v openclaw >/dev/null 2>&1; then

    sudo -u "${OPENCLAW_USER}" \
        bash -c 'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard'

fi

###############################################################################
# FIND OPENCLAW BINARY
###############################################################################

OPENCLAW_BIN=""

for candidate in \
    "/usr/local/bin/openclaw" \
    "/usr/bin/openclaw" \
    "${OPENCLAW_HOME}/.local/bin/openclaw" \
    "${OPENCLAW_HOME}/.npm-global/bin/openclaw"
do
    if [[ -x "${candidate}" ]]; then
        OPENCLAW_BIN="${candidate}"
        break
    fi
done

if [[ -z "${OPENCLAW_BIN}" ]]; then

    OPENCLAW_BIN="$(sudo -u "${OPENCLAW_USER}" bash -lc 'command -v openclaw || true')"

fi

if [[ -z "${OPENCLAW_BIN}" ]]; then
    warn "OpenClaw binary was not found automatically."
    warn "Run: sudo -iu openclaw"
    warn "Then install OpenClaw manually."
else
    log "OpenClaw: ${OPENCLAW_BIN}"
fi

###############################################################################
# OPENCLAW DIRECTORY
###############################################################################

mkdir -p \
    "${OPENCLAW_HOME}/.openclaw" \
    "${OPENCLAW_HOME}/.openclaw/workspace" \
    "${OPENCLAW_HOME}/.openclaw/credentials" \
    "${OPENCLAW_HOME}/.openclaw/logs"

chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" \
    "${OPENCLAW_HOME}/.openclaw"

###############################################################################
# OPENCLAW BASIC CONFIG
###############################################################################

cat > "${OPENCLAW_HOME}/.openclaw/openclaw.json" <<EOF
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

chown "${OPENCLAW_USER}:${OPENCLAW_USER}" \
    "${OPENCLAW_HOME}/.openclaw/openclaw.json"

chmod 600 "${OPENCLAW_HOME}/.openclaw/openclaw.json"

###############################################################################
# OPENCLAW SYSTEMD SERVICE
###############################################################################

if [[ -n "${OPENCLAW_BIN}" ]]; then

    log "Creating OpenClaw systemd service..."

    cat > /etc/systemd/system/rabby-openclaw.service <<EOF
[Unit]
Description=Rabby OpenClaw AI Gateway
After=network-online.target docker.service ollama.service
Wants=network-online.target
Requires=docker.service

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

fi

###############################################################################
# COCKPIT ADMIN DASHBOARD
###############################################################################

log "Installing Cockpit..."

apt-get install -y cockpit cockpit-networkmanager cockpit-packagekit

systemctl enable --now cockpit.socket

###############################################################################
# TAILSCALE
###############################################################################

log "Installing Tailscale..."

if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl enable --now tailscaled || true

###############################################################################
# FIREWALL
###############################################################################

log "Configuring UFW..."

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow 22/tcp comment 'SSH'

# Tailscale
ufw allow in on tailscale0 comment 'Tailscale'

# Local services intentionally NOT exposed:
#
# PostgreSQL 5432 -> localhost only
# Redis       6379 -> localhost only
# n8n         5678 -> localhost only
# OpenClaw    18789 -> localhost only
#
# Cockpit can be reached over Tailscale.

ufw --force enable

###############################################################################
# FAIL2BAN
###############################################################################

systemctl enable --now fail2ban || true

###############################################################################
# MANAGEMENT COMMAND
###############################################################################

cat > /usr/local/bin/rabby <<'EOF'
#!/usr/bin/env bash

case "${1:-}" in

    status)
        echo "===== RABBY AI STATUS ====="
        systemctl --no-pager status rabby-openclaw.service || true
        echo
        systemctl --no-pager status ollama.service || true
        echo
        docker ps
        ;;

    logs)
        journalctl -u rabby-openclaw.service -f
        ;;

    restart)
        systemctl restart rabby-openclaw.service
        docker compose -f /opt/rabby-ai/docker/docker-compose.yml restart
        systemctl restart ollama.service || true
        ;;

    stop)
        systemctl stop rabby-openclaw.service || true
        docker compose -f /opt/rabby-ai/docker/docker-compose.yml stop
        ;;

    start)
        systemctl start rabby-openclaw.service || true
        docker compose -f /opt/rabby-ai/docker/docker-compose.yml start
        systemctl start ollama.service || true
        ;;

    update)
        docker compose \
            -f /opt/rabby-ai/docker/docker-compose.yml \
            pull

        docker compose \
            -f /opt/rabby-ai/docker/docker-compose.yml \
            up -d

        curl -fsSL https://ollama.com/install.sh | sh

        sudo -iu openclaw bash -lc \
            'openclaw update' || true
        ;;

    backup)
        DATE="$(date +%Y%m%d-%H%M%S)"
        mkdir -p /opt/rabby-ai/backups/${DATE}

        docker exec rabby-postgres \
            pg_dump \
            -U rabby \
            rabby \
            > /opt/rabby-ai/backups/${DATE}/postgres.sql

        tar \
            -czf \
            /opt/rabby-ai/backups/${DATE}/openclaw.tar.gz \
            /home/openclaw/.openclaw

        echo "Backup created:"
        echo "/opt/rabby-ai/backups/${DATE}"
        ;;

    channels)
        sudo -iu openclaw openclaw channels status
        ;;

    whatsapp)
        sudo -iu openclaw openclaw channels login
        ;;

    telegram)
        echo
        echo "Configure Telegram:"
        echo
        echo "sudo -iu openclaw openclaw channels add \\"
        echo "  --channel telegram \\"
        echo "  --token YOUR_BOT_TOKEN"
        ;;

    discord)
        echo
        echo "Configure Discord:"
        echo
        echo "sudo -iu openclaw openclaw channels add \\"
        echo "  --channel discord \\"
        echo "  --token YOUR_BOT_TOKEN"
        ;;

    dashboard)
        sudo -iu openclaw openclaw dashboard --no-open
        ;;

    doctor)
        sudo -iu openclaw openclaw doctor
        ;;

    *)
        cat <<HELP

Rabby AI Gateway

Usage:

  rabby status
  rabby logs
  rabby start
  rabby stop
  rabby restart
  rabby update
  rabby backup
  rabby channels
  rabby whatsapp
  rabby telegram
  rabby discord
  rabby dashboard
  rabby doctor

HELP
        ;;

esac
EOF

chmod +x /usr/local/bin/rabby

###############################################################################
# SYSTEMD DOCKER STACK
###############################################################################

cat > /etc/systemd/system/rabby-docker.service <<EOF
[Unit]
Description=Rabby Docker AI Services
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${COMPOSE_DIR}

ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rabby-docker.service
systemctl start rabby-docker.service

###############################################################################
# HEALTH CHECK SCRIPT
###############################################################################

cat > /usr/local/bin/rabby-health <<'EOF'
#!/usr/bin/env bash

echo "======================================"
echo "       RABBY AI HEALTH CHECK"
echo "======================================"

echo
echo "[OpenClaw]"
systemctl is-active rabby-openclaw.service || true

echo
echo "[Ollama]"
systemctl is-active ollama.service || true

echo
echo "[Docker]"
systemctl is-active docker.service || true

echo
echo "[Containers]"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
echo "[Ports]"
ss -lntp | grep -E '18789|5678|5432|6379|11434|9090' || true

echo
echo "[Disk]"
df -h /

echo
echo "[Memory]"
free -h

echo
echo "[Tailscale]"
tailscale status 2>/dev/null || true

echo
echo "======================================"
EOF

chmod +x /usr/local/bin/rabby-health

###############################################################################
# SAVE INSTALLATION INFORMATION
###############################################################################

cat > "${APP_DIR}/INSTALLATION.txt" <<EOF
RABBY AI GATEWAY
================

Installed:
- OpenClaw
- Ollama
- Docker
- Docker Compose
- PostgreSQL
- Redis
- n8n
- Cockpit
- Tailscale
- UFW
- Fail2ban

Directories:
APP:       ${APP_DIR}
DATA:      ${DATA_DIR}
COMPOSE:   ${COMPOSE_DIR}
BACKUPS:   ${BACKUP_DIR}

Local services:

OpenClaw:
http://127.0.0.1:${OPENCLAW_PORT}

n8n:
http://127.0.0.1:${N8N_PORT}

Cockpit:
https://SERVER-IP:${COCKPIT_PORT}

Ollama:
http://127.0.0.1:11434

PostgreSQL:
127.0.0.1:${POSTGRES_PORT}

Redis:
127.0.0.1:${REDIS_PORT}

Commands:

rabby status
rabby logs
rabby restart
rabby update
rabby backup
rabby channels
rabby whatsapp
rabby telegram
rabby discord
rabby dashboard
rabby doctor
rabby-health

IMPORTANT:

OpenClaw token:
${OPENCLAW_TOKEN}

PostgreSQL database:
${POSTGRES_DB}

PostgreSQL user:
${POSTGRES_USER}

PostgreSQL password:
${POSTGRES_PASSWORD}

Redis password:
${REDIS_PASSWORD}

n8n encryption key:
${N8N_ENCRYPTION_KEY}

DO NOT publish this file.

WhatsApp:
Use a dedicated WhatsApp number.
Run:
rabby whatsapp

Telegram:
Create a Telegram bot and run:
sudo -iu openclaw openclaw channels add --channel telegram --token YOUR_TOKEN

Discord:
Create a Discord bot and run:
sudo -iu openclaw openclaw channels add --channel discord --token YOUR_TOKEN

Remote access:
Run:
tailscale up

Then use the Tailscale IP to access the server.

EOF

chmod 600 "${APP_DIR}/INSTALLATION.txt"

###############################################################################
# FINAL PERMISSIONS
###############################################################################

chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" \
    "${OPENCLAW_HOME}/.openclaw"

chmod 700 \
    "${OPENCLAW_HOME}/.openclaw"

###############################################################################
# FINAL HEALTH CHECK
###############################################################################

log "Running health checks..."

sleep 5

systemctl is-active docker.service || true
systemctl is-active ollama.service || true
systemctl is-active rabby-docker.service || true
systemctl is-active rabby-openclaw.service || true

docker ps || true

###############################################################################
# FINAL OUTPUT
###############################################################################

clear

echo
echo "============================================================"
echo "                 RABBY AI GATEWAY READY"
echo "============================================================"
echo
echo "OpenClaw:"
echo "  http://127.0.0.1:${OPENCLAW_PORT}"
echo
echo "n8n:"
echo "  http://127.0.0.1:${N8N_PORT}"
echo
echo "Cockpit:"
echo "  https://SERVER-IP:${COCKPIT_PORT}"
echo
echo "Ollama:"
echo "  http://127.0.0.1:11434"
echo
echo "Management:"
echo "  rabby status"
echo "  rabby-health"
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
echo "Tailscale:"
echo "  tailscale up"
echo
echo "Installation details:"
echo "  ${APP_DIR}/INSTALLATION.txt"
echo
echo "============================================================"
echo "IMPORTANT SECURITY:"
echo "Database/Redis/n8n/OpenClaw ports are localhost-only."
echo "Use Tailscale or a reverse proxy for remote access."
echo "============================================================"
echo

RABBY_INSTALL

chmod +x /root/install-rabby-ai.sh

bash /root/install-rabby-ai.sh
