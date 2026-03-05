#!/usr/bin/env bash
###############################################################################
# LibreNMS Docker Deployment Script
# Target OS: Ubuntu 24.04 LTS
#
# This script automates the deployment steps from DEPLOY.md:
#   1. Installs Docker Engine (if not present)
#   2. Creates .env from .env.example (prompts for passwords)
#   3. Prompts for SNMP community string
#   4. Starts the full Docker Compose stack
#   5. Waits for health checks to pass
#
# Usage:
#   chmod +x deploy.sh
#   sudo ./deploy.sh
#
# Options:
#   --noninteractive    Use defaults/env vars, no prompts (for automation)
#
# Environment variables (for --noninteractive mode):
#   DEPLOY_TZ              Timezone (default: America/New_York)
#   DEPLOY_HTTP_PORT       Web UI port (default: 8000)
#   DEPLOY_SNMP_COMMUNITY  SNMP community string (default: public)
#
# Re-running is safe — it skips steps that are already complete.
###############################################################################

set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────────────────
NONINTERACTIVE=false
for arg in "$@"; do
    case "$arg" in
        --noninteractive) NONINTERACTIVE=true ;;
        --help|-h)
            echo "Usage: sudo $0 [--noninteractive]"
            echo "  --noninteractive  Use defaults/env vars, skip all prompts"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Usage: sudo $0 [--noninteractive]" >&2
            exit 1
            ;;
    esac
done

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Utility: escape a string for use in sed replacement ──────────────────────
sed_escape() {
    # Escape characters special in sed replacement strings: \ & | newline
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# ── Utility: set a KEY=VALUE in a file (safe, no sed injection) ──────────────
set_env_value() {
    local file="$1" key="$2" value="$3"
    local escaped_value
    escaped_value="$(sed_escape "$value")"
    sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$file"
}

# ── Pre-flight checks ───────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f compose.yml ]]; then
    err "compose.yml not found in $SCRIPT_DIR"
    err "Run this script from the docker/ directory."
    exit 1
fi

if [[ ! -f librenms.env ]]; then
    err "librenms.env not found in $SCRIPT_DIR"
    err "Ensure all deployment files are present (see DEPLOY.md)."
    exit 1
fi

if ! command -v openssl &>/dev/null; then
    err "openssl is required for password generation but was not found."
    err "Install it with: sudo apt install -y openssl"
    exit 1
fi

echo ""
echo "========================================"
echo "  LibreNMS Docker Deployment"
echo "========================================"
echo ""

# ── Step 1: Install Docker Engine ────────────────────────────────────────────
install_docker() {
    info "Installing Docker Engine..."

    # Remove conflicting packages
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        apt remove -y "$pkg" 2>/dev/null || true
    done

    apt update
    apt install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    ok "Docker installed successfully."
}

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    ok "Docker and Docker Compose are already installed."
    docker --version
    docker compose version
else
    install_docker
fi

# ── Step 2: Create .env file ─────────────────────────────────────────────────
generate_password() {
    # Use alphanumeric + safe symbols only (avoids shell/sed/MySQL quoting issues)
    openssl rand -base64 32 | tr -d '/+=' | head -c 32
}

validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        err "Invalid port number: $port (must be 1–65535)"
        return 1
    fi
}

if [[ -f .env ]]; then
    # Verify the .env doesn't still have placeholder passwords
    if grep -qE '^MYSQL_ROOT_PASSWORD=CHANGE_ME' .env || grep -qE '^MYSQL_PASSWORD=CHANGE_ME' .env; then
        warn ".env file exists but still has placeholder passwords."
        warn "Removing it and re-creating..."
        rm -f .env
    else
        ok ".env file already exists — skipping creation."
        warn "To reconfigure, delete .env and re-run this script."
    fi
fi

if [[ ! -f .env ]]; then
    info "Creating .env file from .env.example..."

    if [[ ! -f .env.example ]]; then
        err ".env.example not found in $SCRIPT_DIR"
        exit 1
    fi

    # Build .env in a temp file, then move atomically to prevent partial config
    ENV_TMP="$(mktemp "${SCRIPT_DIR}/.env.tmp.XXXXXX")"
    # Ensure temp file is cleaned up on error
    trap 'rm -f "$ENV_TMP"' EXIT
    cp .env.example "$ENV_TMP"
    chmod 600 "$ENV_TMP"

    # Prompt for timezone (or use env var in noninteractive mode)
    if [[ "$NONINTERACTIVE" == true ]]; then
        TZ="${DEPLOY_TZ:-America/New_York}"
    else
        echo ""
        read -rp "Timezone [America/New_York]: " INPUT_TZ
        TZ="${INPUT_TZ:-America/New_York}"
    fi

    # Generate secure MySQL passwords
    echo ""
    info "Generating secure MySQL passwords..."
    MYSQL_ROOT_PW="$(generate_password)"
    MYSQL_USER_PW="$(generate_password)"

    if [[ -z "$MYSQL_ROOT_PW" || -z "$MYSQL_USER_PW" ]]; then
        rm -f "$ENV_TMP"
        err "Failed to generate passwords. Check that openssl is working."
        exit 1
    fi

    echo ""
    echo -e "  MySQL root password:     ${CYAN}${MYSQL_ROOT_PW}${NC}"
    echo -e "  MySQL librenms password:  ${CYAN}${MYSQL_USER_PW}${NC}"
    echo ""
    warn "Save these passwords! They will not be shown again."
    echo ""

    # Prompt for HTTP port (or use env var in noninteractive mode)
    if [[ "$NONINTERACTIVE" == true ]]; then
        HTTP_PORT="${DEPLOY_HTTP_PORT:-8000}"
    else
        read -rp "Web UI port [8000]: " INPUT_PORT
        HTTP_PORT="${INPUT_PORT:-8000}"
    fi
    validate_port "$HTTP_PORT"

    # Write values into temp .env (using safe sed helper)
    set_env_value "$ENV_TMP" "TZ" "$TZ"
    set_env_value "$ENV_TMP" "MYSQL_ROOT_PASSWORD" "$MYSQL_ROOT_PW"
    set_env_value "$ENV_TMP" "MYSQL_PASSWORD" "$MYSQL_USER_PW"
    set_env_value "$ENV_TMP" "LIBRENMS_HTTP_PORT" "$HTTP_PORT"

    # Atomic move into place
    mv "$ENV_TMP" .env
    trap - EXIT

    # Restrict permissions — only root should read the passwords
    chmod 600 .env

    ok ".env file created (permissions: 600)."

    # Clear password variables from memory
    unset MYSQL_ROOT_PW MYSQL_USER_PW
fi

# ── Step 3: Configure SNMP community string ──────────────────────────────────
CURRENT_COMMUNITY=$(grep -E '^LIBRENMS_SNMP_COMMUNITY=' librenms.env | cut -d'=' -f2-)
if [[ "$CURRENT_COMMUNITY" == "public" ]]; then
    echo ""
    warn "SNMP community string is set to 'public' (insecure default)."

    if [[ "$NONINTERACTIVE" == true ]]; then
        COMMUNITY="${DEPLOY_SNMP_COMMUNITY:-public}"
    else
        read -rp "Enter your SNMP community string [public]: " INPUT_COMMUNITY
        COMMUNITY="${INPUT_COMMUNITY:-public}"
    fi

    if [[ "$COMMUNITY" != "public" ]]; then
        set_env_value librenms.env "LIBRENMS_SNMP_COMMUNITY" "$COMMUNITY"
        ok "SNMP community string updated."
    else
        warn "Keeping default 'public' — change this for production use."
    fi
else
    ok "SNMP community string is already configured."
fi

# ── Step 4: Pull images and start the stack ──────────────────────────────────
echo ""
info "Pulling Docker images (this may take a few minutes on first run)..."
docker compose pull

echo ""
info "Starting LibreNMS stack..."
docker compose up -d

# ── Step 5: Wait for health checks ──────────────────────────────────────────
echo ""
info "Waiting for containers to become healthy..."

MAX_WAIT=120
ELAPSED=0
INTERVAL=5
FAILED=false

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    # Check if db and redis are healthy, and librenms is running
    DB_HEALTH=$(docker inspect --format='{{.State.Health.Status}}' librenms_db 2>/dev/null || echo "missing")
    REDIS_HEALTH=$(docker inspect --format='{{.State.Health.Status}}' librenms_redis 2>/dev/null || echo "missing")
    LIBRENMS_HEALTH=$(docker inspect --format='{{.State.Health.Status}}' librenms 2>/dev/null || echo "missing")

    # Detect containers that have exited or are in a restart loop
    for cname in librenms_db librenms_redis librenms; do
        CSTATE=$(docker inspect --format='{{.State.Status}}' "$cname" 2>/dev/null || echo "missing")
        if [[ "$CSTATE" == "exited" || "$CSTATE" == "dead" ]]; then
            echo ""
            err "Container $cname has stopped (state: $CSTATE)."
            err "Check logs with: docker compose logs ${cname#librenms_}"
            FAILED=true
            break 2
        fi
    done

    if [[ "$DB_HEALTH" == "healthy" && "$REDIS_HEALTH" == "healthy" && "$LIBRENMS_HEALTH" == "healthy" ]]; then
        break
    fi

    echo -n "."
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""

if [[ "$FAILED" == true ]]; then
    err "Deployment failed — a container exited unexpectedly."
    info "Run 'docker compose ps' and 'docker compose logs' to diagnose."
    exit 1
elif [[ $ELAPSED -ge $MAX_WAIT ]]; then
    warn "Some containers may not be fully healthy yet."
    warn "  db=$DB_HEALTH  redis=$REDIS_HEALTH  librenms=$LIBRENMS_HEALTH"
    echo "  Check status with: docker compose ps"
else
    ok "All core containers are healthy!"
fi

# ── Step 6: Show status and next steps ───────────────────────────────────────
echo ""
info "Container status:"
docker compose ps
echo ""

# Determine server IP for the access URL
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
SERVER_IP="${SERVER_IP:-YOUR-SERVER-IP}"
HTTP_PORT=$(grep -E '^LIBRENMS_HTTP_PORT=' .env | cut -d'=' -f2-)
HTTP_PORT="${HTTP_PORT:-8000}"

echo "========================================"
echo -e "  ${GREEN}Deployment complete!${NC}"
echo "========================================"
echo ""
echo -e "  Web UI:  ${CYAN}http://${SERVER_IP}:${HTTP_PORT}${NC}"
echo ""
echo "  Next steps:"
echo "    1. Open the URL above in your browser"
echo "    2. Create your admin account"
echo "    3. Go to Settings → Validate Config"
echo "    4. Add your first device under Devices → Add Device"
echo ""
echo "  Useful commands:"
echo "    docker compose ps              # Check container status"
echo "    docker compose logs -f         # Follow all logs"
echo "    docker compose logs librenms   # Logs for web container"
echo "    docker compose down            # Stop all containers"
echo "    docker compose up -d           # Start all containers"
echo "    docker compose pull && docker compose up -d   # Update"
echo ""
