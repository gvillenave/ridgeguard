#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

SYSCTL_FILE="/etc/sysctl.d/99-server-hardening.conf"

info "Applying kernel network hardening..."

SYSCTL_CONTENT="# Server hardening - applied by ridgeguard
# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Log martian packets (spoofed source addresses)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Reverse path filtering (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1"

# Check if already applied with same content
if [[ -f "$SYSCTL_FILE" ]] && diff -q <(echo "$SYSCTL_CONTENT") "$SYSCTL_FILE" &>/dev/null; then
    info "Sysctl hardening already applied, skipping"
    exit 0
fi

echo "$SYSCTL_CONTENT" > "$SYSCTL_FILE"

info "Loading sysctl settings..."
sysctl --system > /dev/null 2>&1

success "Kernel network hardening applied"
