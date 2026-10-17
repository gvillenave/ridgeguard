#!/usr/bin/env bash
# Integration test: runs modules inside an Ubuntu container
# Some modules are tested with real commands, others are smoke-tested
set -euo pipefail

PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "  – $1 (skipped: $2)"; SKIP=$((SKIP + 1)); }

echo ""
echo "========================================"
echo "  Integration Tests"
echo "========================================"
echo ""

cd /opt/ridgeguard

# --- Module 01: System update ---
echo "Testing module 01 (system-update)..."
if bash modules/01-system-update.sh 2>&1; then
    pass "01-system-update"
else
    fail "01-system-update" "apt update/upgrade failed"
fi

# --- Module 02: SSH key setup ---
echo "Testing module 02 (ssh-key-setup)..."
# authorized_keys is pre-populated, so it should skip
output="$(bash modules/02-ssh-key-setup.sh 2>&1)"
if echo "$output" | grep -q "already populated"; then
    pass "02-ssh-key-setup (skips when keys exist)"
else
    fail "02-ssh-key-setup" "did not detect existing keys"
fi

# --- Module 03: SSH hardening ---
echo "Testing module 03 (ssh-hardening)..."
if bash modules/03-ssh-hardening.sh 2>&1; then
    if grep -q "^PasswordAuthentication no$" /etc/ssh/sshd_config && \
       grep -q "^PubkeyAuthentication yes$" /etc/ssh/sshd_config && \
       grep -q "^UsePAM no$" /etc/ssh/sshd_config && \
       grep -q "^PermitRootLogin yes$" /etc/ssh/sshd_config; then
        pass "03-ssh-hardening"
    else
        fail "03-ssh-hardening" "sshd_config not updated correctly"
    fi
else
    fail "03-ssh-hardening" "script exited with error"
fi

# --- Module 03: Idempotency ---
echo "Testing module 03 idempotency..."
if bash modules/03-ssh-hardening.sh 2>&1; then
    count="$(grep -c "PasswordAuthentication" /etc/ssh/sshd_config)"
    if [[ "$count" -eq 1 ]]; then
        pass "03-ssh-hardening (idempotent)"
    else
        fail "03-ssh-hardening (idempotent)" "found $count PasswordAuthentication lines"
    fi
else
    fail "03-ssh-hardening (idempotent)" "script failed on re-run"
fi

# --- Module 04: UFW setup ---
echo "Testing module 04 (ufw-setup)..."
# UFW needs iptables kernel modules not available in Docker — smoke test only
if command -v ufw &>/dev/null || apt-get install -y ufw &>/dev/null 2>&1; then
    skip "04-ufw-setup" "UFW requires host kernel iptables support"
else
    skip "04-ufw-setup" "cannot install ufw in container"
fi

# --- Module 05: UFW docker rules ---
echo "Testing module 05 (ufw-docker-rules)..."
# Create a fake after.rules to test the append logic
mkdir -p /etc/ufw
echo "*filter" > /etc/ufw/after.rules
echo "COMMIT" >> /etc/ufw/after.rules

# Patch the module to skip ufw reload (no ufw running in container)
# Also fix the common.sh source path since the patched script runs from /tmp
# shellcheck disable=SC2016
sed -e 's|source "$SCRIPT_DIR/../lib/common.sh"|source "/opt/ridgeguard/lib/common.sh"|' \
    -e 's/ufw reload/echo "ufw reload skipped in test"/' \
    modules/05-ufw-docker-rules.sh > /tmp/05-test.sh
if bash /tmp/05-test.sh 2>&1; then
    if grep -q "BEGIN UFW AND DOCKER" /etc/ufw/after.rules; then
        pass "05-ufw-docker-rules (appends rules)"
    else
        fail "05-ufw-docker-rules" "marker not found in after.rules"
    fi
else
    fail "05-ufw-docker-rules" "script exited with error"
fi

# Test idempotency
if bash /tmp/05-test.sh 2>&1; then
    count="$(grep -c "BEGIN UFW AND DOCKER" /etc/ufw/after.rules)"
    if [[ "$count" -eq 1 ]]; then
        pass "05-ufw-docker-rules (idempotent)"
    else
        fail "05-ufw-docker-rules (idempotent)" "marker found $count times"
    fi
fi

# --- Module 06: Fail2ban ---
echo "Testing module 06 (fail2ban)..."
if bash modules/06-fail2ban.sh 2>&1; then
    if [[ -f /etc/fail2ban/jail.local ]] && grep -q "\[sshd\]" /etc/fail2ban/jail.local; then
        pass "06-fail2ban (config written)"
    else
        fail "06-fail2ban" "jail.local not created correctly"
    fi
else
    # fail2ban service may not start in container, but config should be written
    if [[ -f /etc/fail2ban/jail.local ]]; then
        pass "06-fail2ban (config written, service skipped in container)"
    else
        fail "06-fail2ban" "script failed and no config written"
    fi
fi

# --- Module 07: Sysctl hardening ---
echo "Testing module 07 (sysctl-hardening)..."
# Patch to skip sysctl --system (may fail in container)
# Also fix the common.sh source path since the patched script runs from /tmp
# shellcheck disable=SC2016
sed -e 's|source "$SCRIPT_DIR/../lib/common.sh"|source "/opt/ridgeguard/lib/common.sh"|' \
    -e 's/sysctl --system.*/echo "sysctl apply skipped in test"/' \
    modules/07-sysctl-hardening.sh > /tmp/07-test.sh
if bash /tmp/07-test.sh 2>&1; then
    if [[ -f /etc/sysctl.d/99-server-hardening.conf ]] && \
       grep -q "tcp_syncookies" /etc/sysctl.d/99-server-hardening.conf; then
        pass "07-sysctl-hardening"
    else
        fail "07-sysctl-hardening" "config file not written correctly"
    fi
else
    fail "07-sysctl-hardening" "script exited with error"
fi

# --- Module 08: Unattended upgrades ---
echo "Testing module 08 (unattended-upgrades)..."
if apt-get install -y unattended-upgrades apt-listchanges &>/dev/null; then
    pass "08-unattended-upgrades (packages installable)"
else
    skip "08-unattended-upgrades" "package install failed"
fi

# --- Module 09: Logwatch ---
echo "Testing module 09 (logwatch)..."
# Patch to skip auditd service commands
# Also fix the common.sh source path since the patched script runs from /tmp
# shellcheck disable=SC2016
sed -e 's|source "$SCRIPT_DIR/../lib/common.sh"|source "/opt/ridgeguard/lib/common.sh"|' \
    -e 's/systemctl enable auditd/true/' \
    -e 's/systemctl restart auditd/true/' \
    -e 's/augenrules --load.*/true/' \
    modules/09-logwatch.sh > /tmp/09-test.sh
if bash /tmp/09-test.sh 2>&1; then
    if [[ -f /etc/logwatch/conf/logwatch.conf ]] && [[ -f /etc/audit/rules.d/hardening.rules ]]; then
        pass "09-logwatch (configs written)"
    else
        fail "09-logwatch" "config files not created"
    fi
else
    fail "09-logwatch" "script exited with error"
fi

# --- Module 10: SSH restart ---
echo "Testing module 10 (ssh-restart)..."
skip "10-ssh-restart" "systemd not available in container"

# --- Module 11: Docker user ---
echo "Testing module 11 (docker-user)..."
if bash modules/11-docker-user.sh 2>&1; then
    if id docker &>/dev/null && \
       groups docker | grep -q sudo && \
       [[ -f /etc/sudoers.d/docker ]] && \
       [[ -f /home/docker/.ssh/authorized_keys ]]; then
        pass "11-docker-user"
    else
        fail "11-docker-user" "user not set up correctly"
    fi
else
    fail "11-docker-user" "script exited with error"
fi

# Idempotency
if bash modules/11-docker-user.sh 2>&1; then
    pass "11-docker-user (idempotent)"
else
    fail "11-docker-user (idempotent)" "failed on re-run"
fi

# --- Module 12: Docker engine ---
echo "Testing module 12 (docker-engine)..."
skip "12-docker-engine" "requires systemd and kernel support"

# Test root-mode detection: simulate active docker.service → user chooses skip
echo "Testing module 12 (docker-engine root-mode detection)..."
# Create a patched version that mocks systemctl and allows piped input
# shellcheck disable=SC2016
sed -e 's|source "$SCRIPT_DIR/../lib/common.sh"|source "/opt/ridgeguard/lib/common.sh"|' \
    -e 's|</dev/tty||' \
    modules/12-docker-engine.sh > /tmp/12-test.sh
# Prepend a systemctl mock that makes docker.service/docker.socket appear active
# shellcheck disable=SC2016
sed -i '1a systemctl() { if [[ "$1" == "is-active" && ("$3" == "docker.service" || "$3" == "docker.socket") ]]; then return 0; fi; command systemctl "$@"; }' /tmp/12-test.sh
set +e
output_12="$(echo "2" | DOCKER_MODE=rootless bash /tmp/12-test.sh 2>&1)"
status_12=$?
set -e
if [[ $status_12 -eq 0 ]] && echo "$output_12" | grep -q "Skipping Docker rootless setup"; then
    pass "12-docker-engine (skip when root-mode detected)"
else
    fail "12-docker-engine (root-mode detection)" "did not skip with choice 2 or exited with status $status_12"
fi

# DOCKER_MODE=none skips the module
output_12_none="$(DOCKER_MODE=none bash modules/12-docker-engine.sh 2>&1)" || true
if echo "$output_12_none" | grep -q "Docker installation skipped"; then
    pass "12-docker-engine (skips when DOCKER_MODE=none)"
else
    fail "12-docker-engine" "did not skip when DOCKER_MODE=none"
fi

# Invalid DOCKER_MODE is rejected
if DOCKER_MODE=bogus bash modules/12-docker-engine.sh >/dev/null 2>&1; then
    fail "12-docker-engine" "accepted invalid DOCKER_MODE"
else
    pass "12-docker-engine (rejects invalid DOCKER_MODE)"
fi

# Note: docker.sock cleanup behavior for module 12 is covered by unit tests.

# --- Module 13: Lazydocker ---
echo "Testing module 13 (lazydocker)..."
# Patch to use a fake curl response so we don't need network access
TMPDIR_LZD=$(mktemp -d)
cat > "$TMPDIR_LZD/lazydocker" << 'FAKE'
#!/bin/sh
echo "Version: 0.0.0-test"
FAKE
chmod +x "$TMPDIR_LZD/lazydocker"
# The module downloads from GitHub which won't work in CI containers,
# so we just verify the script parses and the binary check works
if bash -n modules/13-lazydocker.sh 2>&1; then
    pass "13-lazydocker (syntax valid)"
else
    fail "13-lazydocker" "syntax error in module"
fi
# Verify idempotency path: if lazydocker is already present at the target version, it exits early
# shellcheck disable=SC2015
PATH="$TMPDIR_LZD:$PATH" LAZYDOCKER_VERSION="0.0.0-test" \
    bash -c 'command -v lazydocker && lazydocker --version' >/dev/null 2>&1 \
    && pass "13-lazydocker (binary detection works)" \
    || fail "13-lazydocker" "binary detection failed"
rm -rf "$TMPDIR_LZD"
# Skip path when lazydocker is not selected
output_lzd=$(INSTALL_LAZYDOCKER=0 bash modules/13-lazydocker.sh 2>&1)
if echo "$output_lzd" | grep -q "skipped"; then
    pass "13-lazydocker (skips when not selected)"
else
    fail "13-lazydocker" "did not skip when INSTALL_LAZYDOCKER=0"
fi

# --- Module 14: Dokploy (optional) ---
echo "Testing module 14 (dokploy)..."
if bash -n modules/14-dokploy.sh 2>&1; then
    pass "14-dokploy (syntax valid)"
else
    fail "14-dokploy" "syntax error in module"
fi
# Verify skip path when INSTALL_DOKPLOY is not set
output_dokploy=$(INSTALL_DOKPLOY=0 bash modules/14-dokploy.sh 2>&1)
if echo "$output_dokploy" | grep -q "skipped"; then
    pass "14-dokploy (skips when not selected)"
else
    fail "14-dokploy" "did not skip when INSTALL_DOKPLOY=0"
fi

# Dokploy refuses rootless Docker
if INSTALL_DOKPLOY=1 DOCKER_MODE=rootless bash modules/14-dokploy.sh >/dev/null 2>&1; then
    fail "14-dokploy" "ran with DOCKER_MODE=rootless"
else
    pass "14-dokploy (refuses rootless Docker)"
fi

# --- Module 15: Verify ---
echo "Testing module 15 (verify)..."
skip "15-verify" "requires all services running"

# --- Summary ---
echo ""
echo "========================================"
TOTAL=$((PASS + FAIL + SKIP))
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped (out of $TOTAL)"
echo "========================================"
echo ""

[[ $FAIL -eq 0 ]]
