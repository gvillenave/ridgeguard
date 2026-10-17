#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

info "Setting up UFW firewall..."

# Install ufw if not present
if ! command_exists ufw; then
    apt_install ufw
fi

# CRITICAL: Allow SSH FIRST before enabling to prevent lockout
info "Allowing port 22/tcp (SSH) - must be first!"
ufw allow 22/tcp

info "Allowing port 80/tcp (HTTP)..."
ufw allow 80/tcp

info "Allowing port 443/tcp (HTTPS)..."
ufw allow 443/tcp

# Coolify serves its dashboard on 8000 and its realtime/terminal services on
# 6001 and 6002 until a domain is set up. Close them again afterwards:
#   ufw delete allow 8000/tcp (and 6001, 6002)
if [[ "${COOLIFY_PREP:-0}" == "1" ]]; then
    for port in 8000 6001 6002; do
        info "Allowing port ${port}/tcp (Coolify)..."
        ufw allow "${port}/tcp"
    done
fi

info "Setting default policies..."
ufw default deny incoming
ufw default allow outgoing

# Enable UFW (--force skips interactive confirmation)
info "Enabling UFW..."
ufw --force enable

success "UFW enabled with ports 22, 80, 443 allowed"
ufw status verbose
