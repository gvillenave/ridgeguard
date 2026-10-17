#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

info "Restarting SSH service..."

# Detect the correct service name (ssh on Ubuntu, sshd on other distributions)
if systemctl list-unit-files ssh.service &>/dev/null 2>&1; then
    SSH_SERVICE="ssh"
elif systemctl list-unit-files sshd.service &>/dev/null 2>&1; then
    SSH_SERVICE="sshd"
else
    error "Could not find SSH service"
    exit 1
fi

systemctl restart "$SSH_SERVICE"

# Verify it came back up
sleep 2
if systemctl is-active --quiet "$SSH_SERVICE"; then
    success "SSH service ($SSH_SERVICE) restarted successfully"
else
    error "SSH service ($SSH_SERVICE) failed to restart!"
    systemctl status "$SSH_SERVICE" --no-pager
    exit 1
fi
