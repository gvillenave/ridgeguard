#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

# This module is optional — skip if INSTALL_DOKPLOY is not set
if [[ "${INSTALL_DOKPLOY:-0}" != "1" ]]; then
    info "Dokploy installation skipped (not selected)"
    exit 0
fi

# Dokploy needs the system-wide Docker daemon (Docker Swarm)
if [[ "${DOCKER_MODE:-rootful}" != "rootful" ]]; then
    error "Dokploy requires rootful Docker (DOCKER_MODE=${DOCKER_MODE})"
    exit 1
fi

info "Installing Dokploy..."

# Dokploy requires ports 80, 443, and 3000
# Ports 80 and 443 are already opened by module 04-ufw-setup
# Open port 3000 for the Dokploy dashboard
if command_exists ufw; then
    ufw allow 3000/tcp
    info "UFW: allowed port 3000/tcp (Dokploy dashboard)"
fi

# Dokploy manages its own Docker Swarm setup.
# The install script will:
#   - Install Docker if not present (already installed by module 12)
#   - Initialize Docker Swarm
#   - Deploy Dokploy as a Swarm service
curl -sSL https://dokploy.com/install.sh | sh

success "Dokploy installed"
info "Access the dashboard at http://<server-ip>:3000"
