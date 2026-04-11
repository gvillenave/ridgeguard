#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

SSHD_CONFIG="/etc/ssh/sshd_config"

info "Hardening SSH configuration..."

backup_file "$SSHD_CONFIG"

# Set the required directives
set_sshd_option "PasswordAuthentication" "no" "$SSHD_CONFIG"
set_sshd_option "PubkeyAuthentication" "yes" "$SSHD_CONFIG"
set_sshd_option "UsePAM" "no" "$SSHD_CONFIG"
set_sshd_option "PermitRootLogin" "yes" "$SSHD_CONFIG"

# Handle drop-in configs that may override our settings
DROPIN_DIR="/etc/ssh/sshd_config.d"
if [[ -d "$DROPIN_DIR" ]]; then
    for dropin in "$DROPIN_DIR"/*.conf; do
        [[ -f "$dropin" ]] || continue

        if grep -qE '^\s*PasswordAuthentication\s+yes' "$dropin" 2>/dev/null; then
            warn "Overriding PasswordAuthentication in $dropin"
            backup_file "$dropin"
            set_sshd_option "PasswordAuthentication" "no" "$dropin"
        fi
    done
fi

# Ensure privilege separation directory exists (required by sshd -t)
mkdir -p /run/sshd

# Validate configuration
info "Validating sshd configuration..."
if sshd -t 2>&1; then
    success "SSH hardening applied (sshd will be restarted later)"
else
    error "sshd configuration validation failed! Restoring backup..."
    # Find the most recent backup
    latest_backup="$(find "$(dirname "$SSHD_CONFIG")" -maxdepth 1 -name "$(basename "$SSHD_CONFIG").bak.*" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    if [[ -n "$latest_backup" ]]; then
        cp "$latest_backup" "$SSHD_CONFIG"
        warn "Restored $SSHD_CONFIG from $latest_backup"
    fi
    exit 1
fi
