#!/bin/bash
# WireGuard Client Setup for macOS
# Run this on your Mac in Australia
# Usage: bash client-setup-mac.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT_CONF="$SCRIPT_DIR/client-australia.conf"

# --- Install WireGuard ---
if ! command -v wg &> /dev/null; then
    info "Installing WireGuard via Homebrew..."
    if ! command -v brew &> /dev/null; then
        error "Homebrew not found. Install it first: https://brew.sh"
    fi
    brew install wireguard-tools
fi
info "WireGuard is installed: $(which wg)"

# --- Check for config ---
if [[ ! -f "$CLIENT_CONF" ]]; then
    echo ""
    echo -e "${YELLOW}Client config not found at: $CLIENT_CONF${NC}"
    echo ""
    echo "You need to copy the config from your India server."
    echo "Run this on your Mac:"
    echo ""
    echo "  scp user@YOUR_SERVER_IP:/etc/wireguard/client-australia.conf $SCRIPT_DIR/"
    echo ""
    echo "Or paste the config contents into $CLIENT_CONF manually."
    exit 1
fi

info "Found client config: $CLIENT_CONF"
echo ""
cat "$CLIENT_CONF"
echo ""

# --- Provide instructions ---
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Two ways to connect:${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "${YELLOW}Option 1: WireGuard GUI (Recommended)${NC}"
echo "  1. Install 'WireGuard' from the Mac App Store"
echo "  2. Open WireGuard app"
echo "  3. Click 'Import Tunnel(s) from File'"
echo "  4. Select: $CLIENT_CONF"
echo "  5. Click 'Activate' to connect"
echo ""
echo -e "${YELLOW}Option 2: Command line${NC}"
echo "  Connect:     sudo wg-quick up $CLIENT_CONF"
echo "  Disconnect:  sudo wg-quick down $CLIENT_CONF"
echo "  Status:      sudo wg show"
echo ""
echo -e "${YELLOW}Verify it works:${NC}"
echo "  curl -s ifconfig.me    # Should show your India server IP"
echo ""
