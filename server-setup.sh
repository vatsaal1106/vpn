#!/bin/bash
# WireGuard VPN Server Setup Script
# Run this on your India VM (Ubuntu 20.04/22.04/24.04 or Debian 11/12)
# Usage: sudo bash server-setup.sh

set -euo pipefail

# --- Configuration ---
WG_PORT=51820
WG_INTERFACE="wg0"
SERVER_SUBNET="10.66.66.0/24"
SERVER_IP="10.66.66.1"
CLIENT_IP="10.66.66.2"
DNS_SERVERS="1.1.1.1, 1.0.0.1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Checks ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
fi

# Detect the main network interface
SERVER_NIC=$(ip -4 route show default | awk '{print $5}' | head -1)
if [[ -z "$SERVER_NIC" ]]; then
    error "Could not detect default network interface"
fi
info "Detected network interface: $SERVER_NIC"

# Detect public IP
SERVER_PUBLIC_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com)
if [[ -z "$SERVER_PUBLIC_IP" ]]; then
    error "Could not detect public IP. Check your internet connection."
fi
info "Detected public IP: $SERVER_PUBLIC_IP"

# --- Install WireGuard ---
info "Updating packages and installing WireGuard..."
apt-get update -qq
apt-get install -y wireguard qrencode iptables

# --- Generate Keys ---
WG_DIR="/etc/wireguard"
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

if [[ -f "$WG_DIR/server_private.key" ]]; then
    warn "Keys already exist, reusing them"
    SERVER_PRIVATE_KEY=$(cat "$WG_DIR/server_private.key")
    SERVER_PUBLIC_KEY=$(cat "$WG_DIR/server_public.key")
else
    info "Generating server keys..."
    SERVER_PRIVATE_KEY=$(wg genkey)
    SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
    echo "$SERVER_PRIVATE_KEY" > "$WG_DIR/server_private.key"
    echo "$SERVER_PUBLIC_KEY" > "$WG_DIR/server_public.key"
    chmod 600 "$WG_DIR/server_private.key"
fi

if [[ -f "$WG_DIR/client_private.key" ]]; then
    warn "Client keys already exist, reusing them"
    CLIENT_PRIVATE_KEY=$(cat "$WG_DIR/client_private.key")
    CLIENT_PUBLIC_KEY=$(cat "$WG_DIR/client_public.key")
else
    info "Generating client keys..."
    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
    echo "$CLIENT_PRIVATE_KEY" > "$WG_DIR/client_private.key"
    echo "$CLIENT_PUBLIC_KEY" > "$WG_DIR/client_public.key"
    chmod 600 "$WG_DIR/client_private.key"
fi

# Generate preshared key for extra security
if [[ -f "$WG_DIR/preshared.key" ]]; then
    PRESHARED_KEY=$(cat "$WG_DIR/preshared.key")
else
    info "Generating preshared key..."
    PRESHARED_KEY=$(wg genpsk)
    echo "$PRESHARED_KEY" > "$WG_DIR/preshared.key"
    chmod 600 "$WG_DIR/preshared.key"
fi

# --- Enable IP Forwarding ---
info "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# --- Create Server Config ---
info "Creating WireGuard server config..."
cat > "$WG_DIR/$WG_INTERFACE.conf" << EOF
[Interface]
Address = $SERVER_IP/24
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIVATE_KEY

# NAT: masquerade client traffic so it appears to come from the server
PostUp = iptables -t nat -A POSTROUTING -s $SERVER_SUBNET -o $SERVER_NIC -j MASQUERADE
PostUp = iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT
PostUp = iptables -A FORWARD -o $WG_INTERFACE -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s $SERVER_SUBNET -o $SERVER_NIC -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT
PostDown = iptables -D FORWARD -o $WG_INTERFACE -j ACCEPT

[Peer]
# Client (Australia)
PublicKey = $CLIENT_PUBLIC_KEY
PresharedKey = $PRESHARED_KEY
AllowedIPs = $CLIENT_IP/32
EOF

chmod 600 "$WG_DIR/$WG_INTERFACE.conf"

# --- Create Client Config ---
CLIENT_CONF="$WG_DIR/client-australia.conf"
info "Creating client config..."
cat > "$CLIENT_CONF" << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = $DNS_SERVERS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $PRESHARED_KEY
Endpoint = $SERVER_PUBLIC_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 "$CLIENT_CONF"

# --- Start WireGuard ---
info "Starting WireGuard..."
systemctl stop "wg-quick@$WG_INTERFACE" 2>/dev/null || true
systemctl enable "wg-quick@$WG_INTERFACE"
systemctl start "wg-quick@$WG_INTERFACE"

# --- Firewall (ufw) ---
if command -v ufw &> /dev/null; then
    info "Configuring UFW firewall..."
    ufw allow "$WG_PORT/udp" > /dev/null 2>&1
    ufw allow OpenSSH > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
fi

# --- Output ---
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  WireGuard VPN Server is RUNNING!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "Server Public IP:  ${YELLOW}$SERVER_PUBLIC_IP${NC}"
echo -e "Server WG IP:      ${YELLOW}$SERVER_IP${NC}"
echo -e "Listening Port:    ${YELLOW}$WG_PORT${NC}"
echo -e "Interface:         ${YELLOW}$SERVER_NIC${NC}"
echo ""
echo -e "${GREEN}--- Client Config ---${NC}"
echo "Saved to: $CLIENT_CONF"
echo ""
cat "$CLIENT_CONF"
echo ""

# Generate QR code for mobile clients
echo -e "${GREEN}--- QR Code (for WireGuard mobile app) ---${NC}"
qrencode -t ansiutf8 < "$CLIENT_CONF"
echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo "1. Copy the client config above to your Mac"
echo "   Or save it as client-australia.conf and transfer via scp:"
echo "   scp root@$SERVER_PUBLIC_IP:$CLIENT_CONF ~/vpn/client-australia.conf"
echo ""
echo "2. Make sure UDP port $WG_PORT is open in your cloud provider's firewall/security group"
echo "3. Install WireGuard on your Mac and import the config"
echo ""
