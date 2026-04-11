#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

info "Setting up unattended upgrades..."

apt_install unattended-upgrades apt-listchanges

# Enable automatic updates non-interactively
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -plow unattended-upgrades

success "Unattended upgrades enabled"
