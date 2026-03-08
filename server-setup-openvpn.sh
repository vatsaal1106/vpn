#!/bin/bash
# OpenVPN Server Setup Script
# Run this on your India VM (Ubuntu 20.04/22.04/24.04)
# Usage: sudo bash server-setup-openvpn.sh

set -euo pipefail

# --- Configuration ---
OVPN_PORT=1194
OVPN_PROTO="udp"
OVPN_SUBNET="10.8.0.0"
OVPN_MASK="255.255.255.0"
DNS1="1.1.1.1"
DNS2="1.0.0.1"

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

# Detect network interface
SERVER_NIC=$(ip -4 route show default | awk '{print $5}' | head -1)
[[ -z "$SERVER_NIC" ]] && error "Could not detect default network interface"
info "Detected network interface: $SERVER_NIC"

# Detect public IP
SERVER_PUBLIC_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com)
[[ -z "$SERVER_PUBLIC_IP" ]] && error "Could not detect public IP"
info "Detected public IP: $SERVER_PUBLIC_IP"

# --- Install OpenVPN and EasyRSA ---
info "Installing OpenVPN and EasyRSA..."
apt-get update -qq
apt-get install -y openvpn easy-rsa iptables

# --- Setup PKI (certificates) ---
EASYRSA_DIR="/etc/openvpn/easy-rsa"
if [[ -d "$EASYRSA_DIR" ]]; then
    warn "EasyRSA directory exists, reusing it"
else
    info "Setting up PKI..."
    make-cadir "$EASYRSA_DIR"
fi

cd "$EASYRSA_DIR"

# Configure EasyRSA
cat > vars << 'EOF'
set_var EASYRSA_ALGO       ec
set_var EASYRSA_CURVE      prime256v1
set_var EASYRSA_DIGEST     "sha256"
set_var EASYRSA_CA_EXPIRE  3650
set_var EASYRSA_CERT_EXPIRE 3650
set_var EASYRSA_BATCH      "yes"
EOF

if [[ ! -f pki/ca.crt ]]; then
    info "Initializing PKI..."
    ./easyrsa init-pki

    info "Building CA..."
    ./easyrsa build-ca nopass

    info "Generating server certificate..."
    ./easyrsa build-server-full server nopass

    info "Generating client certificate..."
    ./easyrsa build-client-full client-router nopass

    info "Generating TLS auth key..."
    openvpn --genkey secret /etc/openvpn/tls-auth.key
else
    warn "PKI already exists, reusing certificates"
fi

# --- Enable IP Forwarding ---
info "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# --- Create Server Config ---
info "Creating OpenVPN server config..."
cat > /etc/openvpn/server.conf << EOF
port $OVPN_PORT
proto $OVPN_PROTO
dev tun

ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
tls-auth /etc/openvpn/tls-auth.key 0

dh none

topology subnet
server $OVPN_SUBNET $OVPN_MASK

# Route all client traffic through VPN
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS $DNS1"
push "dhcp-option DNS $DNS2"

keepalive 10 120
cipher AES-256-GCM
auth SHA256
user nobody
group nogroup
persist-key
persist-tun

status /var/log/openvpn-status.log
log-append /var/log/openvpn.log
verb 3
EOF

# --- NAT / Firewall rules ---
info "Setting up NAT rules..."

# Remove old rules if they exist
iptables -t nat -D POSTROUTING -s $OVPN_SUBNET/$OVPN_MASK -o "$SERVER_NIC" -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s $OVPN_SUBNET/$OVPN_MASK -o "$SERVER_NIC" -j MASQUERADE

# Make iptables rules persistent
apt-get install -y iptables-persistent
netfilter-persistent save

# --- UFW ---
if command -v ufw &> /dev/null; then
    info "Configuring UFW..."
    ufw allow $OVPN_PORT/$OVPN_PROTO > /dev/null 2>&1
    ufw allow OpenSSH > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
fi

# --- Start OpenVPN ---
info "Starting OpenVPN server..."
systemctl enable openvpn@server
systemctl restart openvpn@server

# Wait a moment and check
sleep 2
if systemctl is-active --quiet openvpn@server; then
    info "OpenVPN server is running!"
else
    error "OpenVPN failed to start. Check: journalctl -u openvpn@server"
fi

# --- Generate .ovpn client file (single file, router-compatible) ---
CLIENT_OVPN="/etc/openvpn/client-router.ovpn"
info "Generating client .ovpn file..."

cat > "$CLIENT_OVPN" << EOF
client
dev tun
proto $OVPN_PROTO
remote $SERVER_PUBLIC_IP $OVPN_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
key-direction 1
verb 3

<ca>
$(cat /etc/openvpn/easy-rsa/pki/ca.crt)
</ca>

<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' /etc/openvpn/easy-rsa/pki/issued/client-router.crt)
</cert>

<key>
$(cat /etc/openvpn/easy-rsa/pki/private/client-router.key)
</key>

<tls-auth>
$(cat /etc/openvpn/tls-auth.key)
</tls-auth>
EOF

chmod 600 "$CLIENT_OVPN"

# --- Output ---
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  OpenVPN Server is RUNNING!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "Server Public IP:  ${YELLOW}$SERVER_PUBLIC_IP${NC}"
echo -e "Port:              ${YELLOW}$OVPN_PORT/$OVPN_PROTO${NC}"
echo -e "Subnet:            ${YELLOW}$OVPN_SUBNET${NC}"
echo ""
echo -e "${GREEN}--- Client .ovpn file ---${NC}"
echo "Saved to: $CLIENT_OVPN"
echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo "1. Download the .ovpn file to your computer:"
echo "   scp root@$SERVER_PUBLIC_IP:$CLIENT_OVPN ~/vpn/client-router.ovpn"
echo ""
echo "2. Open your TP-Link router admin panel (usually 192.168.0.1)"
echo "3. Go to: Advanced > VPN Client > OpenVPN"
echo "4. Upload the .ovpn file"
echo "5. Enable the VPN connection"
echo ""
echo "6. Make sure UDP port $OVPN_PORT is open in your cloud provider's firewall"
echo ""
