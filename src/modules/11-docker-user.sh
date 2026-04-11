#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

info "Setting up '$DOCKER_USER' user..."

# Create user if it doesn't exist
if id "$DOCKER_USER" &>/dev/null; then
    info "User '$DOCKER_USER' already exists"
else
    useradd -m -s /bin/bash -G sudo "$DOCKER_USER"
    # Set shadow password to '*' (no valid password, but NOT locked).
    # With UsePAM=no, sshd rejects users whose shadow entry starts with '!'
    # (locked) before even checking pubkey auth.  '*' means "no password login
    # possible" without triggering the lock check.
    usermod -p '*' "$DOCKER_USER"
    success "User '$DOCKER_USER' created"
fi

# Set up passwordless sudo
SUDOERS_FILE="/etc/sudoers.d/$DOCKER_USER"
if [[ ! -f "$SUDOERS_FILE" ]]; then
    echo "$DOCKER_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"

    if visudo -cf "$SUDOERS_FILE" &>/dev/null; then
        info "Passwordless sudo configured"
    else
        error "Invalid sudoers file, removing"
        rm -f "$SUDOERS_FILE"
        exit 1
    fi
else
    info "Sudoers entry already exists"
fi

# Copy root's SSH keys so the user can log in
ROOT_KEYS="/root/.ssh/authorized_keys"
DOCKER_SSH="/home/$DOCKER_USER/.ssh"

if [[ -s "$ROOT_KEYS" ]]; then
    mkdir -p "$DOCKER_SSH"
    cp "$ROOT_KEYS" "$DOCKER_SSH/authorized_keys"
    chown -R "$DOCKER_USER:$DOCKER_USER" "$DOCKER_SSH"
    chmod 700 "$DOCKER_SSH"
    chmod 600 "$DOCKER_SSH/authorized_keys"
    info "SSH keys copied from root to $DOCKER_USER"
else
    warn "No root SSH keys found to copy"
fi

success "User '$DOCKER_USER' ready with sudo privileges"
