#!/usr/bin/env bash
###############################################################################
# Build a self-extracting LibreNMS installer
#
# Bundles compose.yml, .env.example, librenms.env, and deploy.sh into a
# single executable .sh file that can be copied to any Ubuntu 24.04 server.
#
# Usage:
#   chmod +x build-installer.sh
#   ./build-installer.sh
#
# Output:
#   librenms-installer.sh  (self-extracting, ~15 KB)
#
# On the target server:
#   scp librenms-installer.sh user@server:/tmp/
#   ssh user@server
#   chmod +x /tmp/librenms-installer.sh
#   sudo /tmp/librenms-installer.sh [--noninteractive]
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT="librenms-installer.sh"

# ── Verify required files exist ──────────────────────────────────────────────
REQUIRED_FILES=(compose.yml .env.example librenms.env deploy.sh)
for f in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: Required file '$f' not found in $SCRIPT_DIR" >&2
        exit 1
    fi
done

# ── Create the tar.gz payload ────────────────────────────────────────────────
PAYLOAD_TMP="$(mktemp)"
trap 'rm -f "$PAYLOAD_TMP"' EXIT

tar czf "$PAYLOAD_TMP" "${REQUIRED_FILES[@]}"

PAYLOAD_SIZE=$(wc -c < "$PAYLOAD_TMP")
echo "Payload size: ${PAYLOAD_SIZE} bytes ($(( PAYLOAD_SIZE / 1024 )) KB)"

# ── Build the self-extracting script ─────────────────────────────────────────
cat > "$OUTPUT" << 'HEADER_EOF'
#!/usr/bin/env bash
###############################################################################
# LibreNMS Self-Extracting Installer
# Target OS: Ubuntu 24.04 LTS
#
# This file contains everything needed to deploy LibreNMS via Docker Compose.
# It extracts the deployment files and runs the deploy script.
#
# Usage:
#   chmod +x librenms-installer.sh
#   sudo ./librenms-installer.sh [--noninteractive]
#
# Options:
#   --noninteractive    Skip all prompts, use defaults/env vars
#   --extract-only      Extract files to /opt/librenms without deploying
#   --help              Show this help
#
# Environment variables (for --noninteractive mode):
#   DEPLOY_TZ              Timezone (default: America/New_York)
#   DEPLOY_HTTP_PORT       Web UI port (default: 8000)
#   DEPLOY_SNMP_COMMUNITY  SNMP community string (default: public)
#   LIBRENMS_INSTALL_DIR   Install directory (default: /opt/librenms)
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

EXTRACT_ONLY=false
DEPLOY_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --extract-only) EXTRACT_ONLY=true ;;
        --help|-h)
            echo "Usage: sudo $0 [--noninteractive] [--extract-only]"
            echo ""
            echo "  --noninteractive  Skip all prompts, use defaults/env vars"
            echo "  --extract-only    Extract files without running deployment"
            echo "  --help            Show this help"
            exit 0
            ;;
        *) DEPLOY_ARGS+=("$arg") ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} This installer must be run as root (use sudo)." >&2
    exit 1
fi

INSTALL_DIR="${LIBRENMS_INSTALL_DIR:-/opt/librenms}"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     LibreNMS Docker Installer                ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Find the payload boundary ────────────────────────────────────────────────
# The tar.gz payload starts after the __PAYLOAD_BELOW__ marker line
ARCHIVE_LINE=$(awk '/^__PAYLOAD_BELOW__$/ { print NR + 1; exit }' "$0")

if [[ -z "$ARCHIVE_LINE" ]]; then
    echo -e "${RED}[ERROR]${NC} Could not find payload marker. File may be corrupt." >&2
    exit 1
fi

# ── Extract to install directory ─────────────────────────────────────────────
echo -e "${CYAN}[INFO]${NC}  Extracting to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"

tail -n +"$ARCHIVE_LINE" "$0" | tar xzf - -C "$INSTALL_DIR"

chmod 600 "$INSTALL_DIR/.env.example"
chmod 700 "$INSTALL_DIR/deploy.sh"

echo -e "${GREEN}[OK]${NC}    Files extracted to ${INSTALL_DIR}/"
echo ""

ls -la "$INSTALL_DIR/"
echo ""

if [[ "$EXTRACT_ONLY" == true ]]; then
    echo -e "${GREEN}Done!${NC} Files extracted. To deploy, run:"
    echo "  cd ${INSTALL_DIR} && sudo ./deploy.sh"
    exit 0
fi

# ── Run the deploy script ───────────────────────────────────────────────────
echo -e "${CYAN}[INFO]${NC}  Starting deployment..."
echo ""

cd "$INSTALL_DIR"
exec ./deploy.sh "${DEPLOY_ARGS[@]}"

# ── Everything below this line is the binary tar.gz payload ──────────────────
# Do NOT edit or add lines below the marker.
__PAYLOAD_BELOW__
HEADER_EOF

# ── Append the binary payload ────────────────────────────────────────────────
cat "$PAYLOAD_TMP" >> "$OUTPUT"

chmod +x "$OUTPUT"

echo ""
echo "============================================="
echo "  Built: $OUTPUT"
echo "  Size:  $(wc -c < "$OUTPUT" | tr -d ' ') bytes"
echo "============================================="
echo ""
echo "Transfer to your server and run:"
echo "  scp $OUTPUT user@your-server:/tmp/"
echo "  ssh user@your-server 'chmod +x /tmp/$OUTPUT && sudo /tmp/$OUTPUT'"
echo ""
