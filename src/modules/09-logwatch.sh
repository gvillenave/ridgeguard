#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

info "Setting up logwatch and auditd..."

# Install logwatch
if ! command_exists logwatch; then
    apt_install logwatch
fi

# Configure logwatch
LOGWATCH_CONF_DIR="/etc/logwatch/conf"
LOGWATCH_CONF="$LOGWATCH_CONF_DIR/logwatch.conf"
mkdir -p "$LOGWATCH_CONF_DIR"

if [[ ! -f "$LOGWATCH_CONF" ]]; then
    cat > "$LOGWATCH_CONF" << 'EOF'
Output = stdout
Detail = Med
Range = yesterday
Service = All
EOF
    info "Logwatch configured"
else
    info "Logwatch config already exists, skipping"
fi

# Install and configure auditd
if ! command_exists auditctl; then
    apt_install auditd
fi

AUDIT_RULES="/etc/audit/rules.d/hardening.rules"
if [[ ! -f "$AUDIT_RULES" ]]; then
    cat > "$AUDIT_RULES" << 'EOF'
# Watch critical files for changes
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd_config

# Log all sudo usage
-w /usr/bin/sudo -p x -k sudo_usage
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
EOF
    info "Audit rules written"
else
    info "Audit rules already exist, skipping"
fi

systemctl enable auditd
systemctl restart auditd

# Load rules
augenrules --load > /dev/null 2>&1 || true

success "Logwatch and auditd configured"
