#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root
DOCKER_UID="$(id -u "$DOCKER_USER" 2>/dev/null || echo "")"
PASS="${GREEN}✓${RESET}"
FAIL="${RED}✗${RESET}"

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  Verification Report${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""

check_service() {
    local name="$1" service="$2"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "  $PASS $name"
    else
        echo -e "  $FAIL $name (not running)"
    fi
}

# SSH
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    echo -e "  $PASS SSH service"
else
    echo -e "  $FAIL SSH service (not running)"
fi

# SSH hardening
if grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config 2>/dev/null; then
    echo -e "  $PASS SSH password auth disabled"
else
    echo -e "  $FAIL SSH password auth still enabled"
fi

# UFW
if ufw status | grep -q "Status: active" 2>/dev/null; then
    echo -e "  $PASS UFW active"
else
    echo -e "  $FAIL UFW not active"
fi

# UFW ports
for port in 22 80 443; do
    if ufw status | grep -q "${port}/tcp" 2>/dev/null; then
        echo -e "  $PASS UFW port $port allowed"
    else
        echo -e "  $FAIL UFW port $port not found"
    fi
done

# UFW Docker rules
if grep -q "BEGIN UFW AND DOCKER" /etc/ufw/after.rules 2>/dev/null; then
    echo -e "  $PASS UFW Docker rules"
else
    echo -e "  $FAIL UFW Docker rules missing"
fi

# Fail2ban
check_service "Fail2ban" "fail2ban"

if fail2ban-client status sshd &>/dev/null; then
    echo -e "  $PASS Fail2ban SSH jail"
else
    echo -e "  $FAIL Fail2ban SSH jail not active"
fi

# Sysctl hardening
if [[ -f /etc/sysctl.d/99-server-hardening.conf ]]; then
    echo -e "  $PASS Sysctl hardening"
else
    echo -e "  $FAIL Sysctl hardening missing"
fi

# Unattended upgrades
if dpkg -l unattended-upgrades &>/dev/null 2>&1; then
    echo -e "  $PASS Unattended upgrades"
else
    echo -e "  $FAIL Unattended upgrades not installed"
fi

# Auditd
check_service "Auditd" "auditd"

# Docker user
if id "$DOCKER_USER" &>/dev/null; then
    echo -e "  $PASS Docker user exists"
    if groups "$DOCKER_USER" | grep -q sudo; then
        echo -e "  $PASS Docker user has sudo"
    else
        echo -e "  $FAIL Docker user lacks sudo"
    fi
else
    echo -e "  $FAIL Docker user not found"
fi

# Lazydocker
if command -v lazydocker &>/dev/null; then
    lzd_ver=$(lazydocker --version 2>/dev/null | grep -oP 'Version:\s*\K[\d.]+' || echo "unknown")
    echo -e "  $PASS Lazydocker installed ($lzd_ver)"
else
    echo -e "  $FAIL Lazydocker not installed"
fi

# Dokploy (optional)
if [[ "${INSTALL_DOKPLOY:-0}" == "1" ]]; then
    if docker service ls 2>/dev/null | grep -q dokploy; then
        echo -e "  $PASS Dokploy service running"
    else
        echo -e "  $FAIL Dokploy service not found"
    fi
    if ufw status 2>/dev/null | grep -q "3000/tcp"; then
        echo -e "  $PASS UFW port 3000 allowed (Dokploy)"
    else
        echo -e "  $FAIL UFW port 3000 not open (Dokploy)"
    fi
else
    echo -e "  ${YELLOW}–${RESET} Dokploy (skipped)"
fi

# Docker rootless
if [[ -n "$DOCKER_UID" ]]; then
    info "Running Docker hello-world test..."
    if sudo -u "$DOCKER_USER" \
        XDG_RUNTIME_DIR="/run/user/$DOCKER_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$DOCKER_UID/bus" \
        docker run --rm hello-world &>/dev/null; then
        echo -e "  $PASS Docker rootless (hello-world passed)"
    else
        echo -e "  $FAIL Docker rootless (hello-world failed)"
    fi
else
    echo -e "  $FAIL Docker rootless (user not found)"
fi

echo ""
echo -e "${BOLD}========================================${RESET}"

# Show server IP
SERVER_IP="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")"
echo -e "  Server IP: ${BOLD}$SERVER_IP${RESET}"
echo -e "  SSH:       ${BOLD}ssh root@$SERVER_IP${RESET}"
echo -e "  SSH:       ${BOLD}ssh $DOCKER_USER@$SERVER_IP${RESET}"
if [[ "${INSTALL_DOKPLOY:-0}" == "1" ]]; then
    echo -e "  Dokploy:   ${BOLD}http://$SERVER_IP:3000${RESET}"
fi

echo -e "${BOLD}========================================${RESET}"
echo ""
