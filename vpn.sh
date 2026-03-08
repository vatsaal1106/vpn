#!/bin/bash
# VPN management helper for macOS client
# Usage: ./vpn.sh [up|down|status|test|ip]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT_CONF="$SCRIPT_DIR/client-australia.conf"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

case "${1:-help}" in
    up|connect)
        echo -e "${GREEN}Connecting to India VPN...${NC}"
        sudo wg-quick up "$CLIENT_CONF"
        sleep 2
        IP=$(curl -s --max-time 5 ifconfig.me || echo "unknown")
        echo -e "${GREEN}Connected! Your public IP: ${YELLOW}$IP${NC}"
        ;;
    down|disconnect)
        echo -e "${YELLOW}Disconnecting from VPN...${NC}"
        sudo wg-quick down "$CLIENT_CONF"
        sleep 1
        IP=$(curl -s --max-time 5 ifconfig.me || echo "unknown")
        echo -e "${GREEN}Disconnected. Your public IP: ${YELLOW}$IP${NC}"
        ;;
    status)
        if sudo wg show 2>/dev/null | grep -q "interface"; then
            echo -e "${GREEN}VPN is ACTIVE${NC}"
            sudo wg show
        else
            echo -e "${RED}VPN is NOT connected${NC}"
        fi
        ;;
    test)
        echo "Testing VPN connection..."
        echo -n "Public IP: "
        IP=$(curl -s --max-time 5 ifconfig.me || echo "FAILED")
        echo -e "${YELLOW}$IP${NC}"
        echo -n "DNS leak test: "
        DNS=$(curl -s --max-time 5 https://am.i.mullvad.net/json 2>/dev/null | grep -o '"country":"[^"]*"' || echo "use browser: https://dnsleaktest.com")
        echo -e "${YELLOW}$DNS${NC}"
        echo -n "Ping to VPN server: "
        ping -c 3 10.66.66.1 2>/dev/null || echo -e "${RED}Cannot reach VPN server${NC}"
        ;;
    ip)
        curl -s ifconfig.me
        echo ""
        ;;
    *)
        echo "India VPN Manager"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  up / connect       Connect to India VPN"
        echo "  down / disconnect  Disconnect from VPN"
        echo "  status             Show VPN connection status"
        echo "  test               Test connection and check for leaks"
        echo "  ip                 Show your current public IP"
        ;;
esac
