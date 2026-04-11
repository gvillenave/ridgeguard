#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

info "Updating package lists..."
apt-get update -y

info "Upgrading installed packages..."
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get upgrade -y

success "System update complete"
