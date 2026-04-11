#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

AUTH_KEYS="/root/.ssh/authorized_keys"

if [[ -s "$AUTH_KEYS" ]]; then
    info "authorized_keys already populated, skipping"
    exit 0
fi

info "No SSH public key found for root"

# Ensure .ssh directory exists
mkdir -p /root/.ssh
chmod 700 /root/.ssh

echo "" >&2
echo -e "${BOLD}Paste your public SSH key (starts with ssh-rsa, ssh-ed25519, ecdsa-sha2, sk-ssh):${RESET}" >&2
read -r SSH_KEY < /dev/tty

# Validate key format
if ! echo "$SSH_KEY" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-[a-z0-9]+|sk-ssh-ed25519@[a-z0-9.]+|sk-ecdsa-sha2-[a-z0-9]+@[a-z0-9.]+)\s'; then
    error "Invalid SSH key format. Key must start with ssh-rsa, ssh-ed25519, ecdsa-sha2-*, or sk-ssh-*"
    exit 1
fi

echo "$SSH_KEY" > "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

success "SSH public key installed to $AUTH_KEYS"
