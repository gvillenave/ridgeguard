#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

JAIL_LOCAL="/etc/fail2ban/jail.local"

info "Setting up fail2ban..."

# Install fail2ban
if ! command_exists fail2ban-client; then
    apt_install fail2ban
fi

# Create jail.local (never edit jail.conf — it gets overwritten on update)
if [[ -f "$JAIL_LOCAL" ]] && grep -q '\[sshd\]' "$JAIL_LOCAL" 2>/dev/null; then
    info "fail2ban jail.local already configured, skipping"
else
    info "Creating $JAIL_LOCAL with SSH jail..."
    cat > "$JAIL_LOCAL" << 'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
# OpenSSH 10 throttles repeat offenders itself (PerSourcePenalties) after about
# three failures, so a higher value may never trigger.
maxretry = 3

[sshd]
enabled = true
port = ssh
# Key-only servers log failed attempts as "Connection closed by authenticating
# user ... [preauth]". Only aggressive mode matches those lines.
filter = sshd[mode=aggressive]
backend = systemd
# OpenSSH 9.8+ logs from sshd-session. Ubuntu's defaults-debian.conf only
# matches sshd, so list both.
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session
EOF
fi

info "Enabling and starting fail2ban..."
systemctl enable fail2ban
systemctl restart fail2ban

success "fail2ban enabled with SSH protection"
