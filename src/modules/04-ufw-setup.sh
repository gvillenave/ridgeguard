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

info "Setting default policies..."
ufw default deny incoming
ufw default allow outgoing

# Enable UFW (--force skips interactive confirmation)
info "Enabling UFW..."
ufw --force enable

success "UFW enabled with ports 22, 80, 443 allowed"
ufw status verbose
