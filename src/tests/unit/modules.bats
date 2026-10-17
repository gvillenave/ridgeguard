#!/usr/bin/env bats
# Unit tests for module logic (mocked system commands)

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_DIR="$(dirname "$(dirname "$TEST_DIR")")"
    export NO_COLOR=1
    source "$PROJECT_DIR/lib/common.sh"

    # Create a temp dir for test artifacts
    TEST_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# --- 02-ssh-key-setup: key validation ---

@test "SSH key validation accepts ssh-rsa key" {
    echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB user@host" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-[a-z0-9]+|sk-ssh-ed25519@[a-z0-9.]+|sk-ecdsa-sha2-[a-z0-9]+@[a-z0-9.]+)\s'
}

@test "SSH key validation accepts ssh-ed25519 key" {
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI user@host" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-[a-z0-9]+|sk-ssh-ed25519@[a-z0-9.]+|sk-ecdsa-sha2-[a-z0-9]+@[a-z0-9.]+)\s'
}

@test "SSH key validation accepts ecdsa key" {
    echo "ecdsa-sha2-nistp256 AAAAE2VjZHNh user@host" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-[a-z0-9]+|sk-ssh-ed25519@[a-z0-9.]+|sk-ecdsa-sha2-[a-z0-9]+@[a-z0-9.]+)\s'
}

@test "SSH key validation rejects invalid key" {
    ! echo "not-a-key AAAAB3 user@host" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-[a-z0-9]+|sk-ssh-ed25519@[a-z0-9.]+|sk-ecdsa-sha2-[a-z0-9]+@[a-z0-9.]+)\s'
}

@test "SSH key validation rejects empty input" {
    ! echo "" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-[a-z0-9]+|sk-ssh-ed25519@[a-z0-9.]+|sk-ecdsa-sha2-[a-z0-9]+@[a-z0-9.]+)\s'
}

# --- 03-ssh-hardening: full config transformation ---

@test "SSH hardening applies all four settings to a typical sshd_config" {
    cat > "$TEST_TMP/sshd_config" << 'EOF'
# Authentication:
#PubkeyAuthentication yes
PasswordAuthentication yes
# UsePAM yes
#PermitRootLogin prohibit-password
EOF

    set_sshd_option "PasswordAuthentication" "no" "$TEST_TMP/sshd_config"
    set_sshd_option "PubkeyAuthentication" "yes" "$TEST_TMP/sshd_config"
    set_sshd_option "UsePAM" "no" "$TEST_TMP/sshd_config"
    set_sshd_option "PermitRootLogin" "yes" "$TEST_TMP/sshd_config"

    grep -q "^PasswordAuthentication no$" "$TEST_TMP/sshd_config"
    grep -q "^PubkeyAuthentication yes$" "$TEST_TMP/sshd_config"
    grep -q "^UsePAM no$" "$TEST_TMP/sshd_config"
    grep -q "^PermitRootLogin yes$" "$TEST_TMP/sshd_config"
}

@test "SSH hardening is idempotent" {
    cat > "$TEST_TMP/sshd_config" << 'EOF'
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
PermitRootLogin yes
EOF

    set_sshd_option "PasswordAuthentication" "no" "$TEST_TMP/sshd_config"
    set_sshd_option "PubkeyAuthentication" "yes" "$TEST_TMP/sshd_config"
    set_sshd_option "UsePAM" "no" "$TEST_TMP/sshd_config"
    set_sshd_option "PermitRootLogin" "yes" "$TEST_TMP/sshd_config"

    # Should still have exactly 4 lines (no duplicates)
    local count
    count="$(wc -l < "$TEST_TMP/sshd_config")"
    [[ "$count" -eq 4 ]]
}

# --- 05-ufw-docker-rules: idempotency marker ---

@test "UFW Docker rules marker detection works" {
    echo "# BEGIN UFW AND DOCKER" > "$TEST_TMP/after.rules"
    grep -q "# BEGIN UFW AND DOCKER" "$TEST_TMP/after.rules"
}

@test "UFW Docker rules marker absent when file is empty" {
    touch "$TEST_TMP/after.rules"
    ! grep -q "# BEGIN UFW AND DOCKER" "$TEST_TMP/after.rules"
}

# --- 07-sysctl-hardening: content check ---

@test "Sysctl hardening file has all required settings" {
    local settings=(
        "net.ipv4.conf.all.accept_redirects"
        "net.ipv4.conf.all.send_redirects"
        "net.ipv4.tcp_syncookies"
        "net.ipv4.conf.all.log_martians"
        "net.ipv4.icmp_echo_ignore_broadcasts"
        "net.ipv4.conf.all.rp_filter"
    )

    # Read the module to verify it writes all settings
    for setting in "${settings[@]}"; do
        grep -q "$setting" "$PROJECT_DIR/modules/07-sysctl-hardening.sh"
    done
}

# --- 09-logwatch: audit rules content ---

@test "Audit rules watch critical files" {
    local files=("/etc/passwd" "/etc/shadow" "/etc/ssh/sshd_config")

    for file in "${files[@]}"; do
        grep -q "$file" "$PROJECT_DIR/modules/09-logwatch.sh"
    done
}

# --- 12-docker-engine: root-mode detection ---

# Helper: creates a test script that mimics the module's root-mode detection block.
# The full module requires root and systemd, which aren't available in test.
# </dev/tty is intentionally omitted so input can be piped for testing.
# Args: $1 = "systemctl" (mock systemctl as active) or "socket" (create fake socket only)
create_docker_detect_script() {
    local mode="${1:-systemctl}"
    local mock_systemctl='systemctl() { return 0; }'
    local sock_path="$TEST_TMP/docker.sock"
    if [[ "$mode" == "socket" ]]; then
        # systemctl reports inactive; detection triggers via socket file only
        mock_systemctl='systemctl() { return 1; }'
        # Create a Unix socket so [[ -S ]] matches (requires python3)
        if ! command -v python3 >/dev/null 2>&1; then
            echo "python3 not found, cannot create Unix socket for test" >&2
            return 1
        fi
        if ! python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.bind('$sock_path')"; then
            echo "failed to create Unix socket at $sock_path" >&2
            return 2
        fi
    fi
    cat > "$TEST_TMP/detect.sh" << SCRIPT
#!/usr/bin/env bash
set -euo pipefail
NO_COLOR=1
BOLD='' RESET='' RED='' GREEN='' YELLOW='' BLUE=''
info()  { echo "[INFO] \$*" >&2; }
warn()  { echo "[WARN] \$*" >&2; }
$mock_systemctl
if systemctl is-active --quiet docker.service 2>/dev/null || \
   systemctl is-active --quiet docker.socket 2>/dev/null || \
   [[ -S "$sock_path" ]]; then
    warn "Docker appears to be installed in root (system-wide) mode, or a leftover /var/run/docker.sock was found."
    read -rp "Choose [1/2] (default: 2 = skip): " docker_choice
    case "\${docker_choice:-2}" in
        1)
            info "Proceeding with rootless mode installation..."
            ;;
        *) info "Skipping Docker rootless setup, keeping existing root-mode installation."; exit 0 ;;
    esac
fi
echo "CONTINUED"
SCRIPT
    chmod +x "$TEST_TMP/detect.sh"
}

@test "Docker engine skips when root-mode Docker is active and user chooses skip" {
    create_docker_detect_script

    # User chooses "2" (skip)
    run bash -c 'echo "2" | bash "$1" 2>&1' -- "$TEST_TMP/detect.sh"
    [[ $status -eq 0 ]]
    [[ "$output" == *"Skipping Docker rootless setup"* ]]
    [[ "$output" != *"CONTINUED"* ]]
}

@test "Docker engine continues when root-mode Docker is active and user chooses reinstall" {
    create_docker_detect_script

    # User chooses "1" (reinstall)
    run bash -c 'echo "1" | bash "$1" 2>&1' -- "$TEST_TMP/detect.sh"
    [[ $status -eq 0 ]]
    [[ "$output" == *"Proceeding with rootless mode"* ]]
    [[ "$output" == *"CONTINUED"* ]]
}

@test "Docker engine detects root-mode via socket file when systemd is inactive" {
    create_docker_detect_script "socket"
    local rc=$?
    [[ $rc -eq 1 ]] && skip "python3 required to create Unix socket"
    [[ $rc -eq 0 ]] || fail "failed to create Unix socket for test (exit $rc)"

    # User chooses "2" (skip) — detection should trigger from socket alone
    run bash -c 'echo "2" | bash "$1" 2>&1' -- "$TEST_TMP/detect.sh"
    [[ $status -eq 0 ]]
    [[ "$output" == *"Skipping Docker rootless setup"* ]]
    [[ "$output" != *"CONTINUED"* ]]
}

@test "Docker engine detects root-mode Docker warning message" {
    # Verify the module contains the root-mode detection logic
    grep -q "systemctl is-active --quiet docker.service" "$PROJECT_DIR/modules/12-docker-engine.sh"
    grep -q '\-S /var/run/docker.sock' "$PROJECT_DIR/modules/12-docker-engine.sh"
    grep -q "appears to be installed in root" "$PROJECT_DIR/modules/12-docker-engine.sh"
}

@test "Docker engine removes leftover docker.sock after disabling daemon" {
    # Verify the module cleans up /var/run/docker.sock after stopping the daemon
    grep -q 'rm -f /var/run/docker.sock' "$PROJECT_DIR/modules/12-docker-engine.sh"
}

@test "Docker engine socket cleanup occurs after daemon disable" {
    # Verify the rm comes after the systemctl disable (order matters)
    local disable_line rm_line
    disable_line=$(grep -n 'systemctl disable --now docker.service docker.socket' "$PROJECT_DIR/modules/12-docker-engine.sh" | head -1 | cut -d: -f1)
    rm_line=$(grep -n 'rm -f /var/run/docker.sock' "$PROJECT_DIR/modules/12-docker-engine.sh" | head -1 | cut -d: -f1)
    [[ "$rm_line" -gt "$disable_line" ]]
}

@test "Docker engine module supports rootful, rootless and none modes" {
    grep -q 'install_rootful' "$PROJECT_DIR/modules/12-docker-engine.sh"
    grep -q 'install_rootless' "$PROJECT_DIR/modules/12-docker-engine.sh"
    grep -q 'DOCKER_MODE=none' "$PROJECT_DIR/modules/12-docker-engine.sh"
}

@test "Docker engine rootful mode does not disable the system daemon" {
    # The disable call must live inside install_rootless only
    local fn_line disable_line
    fn_line=$(grep -n '^install_rootless()' "$PROJECT_DIR/modules/12-docker-engine.sh" | cut -d: -f1)
    disable_line=$(grep -n 'systemctl disable --now docker.service' "$PROJECT_DIR/modules/12-docker-engine.sh" | head -1 | cut -d: -f1)
    [[ "$disable_line" -gt "$fn_line" ]]
}

@test "lazydocker module skips unless INSTALL_LAZYDOCKER=1" {
    grep -q 'INSTALL_LAZYDOCKER:-0' "$PROJECT_DIR/modules/13-lazydocker.sh"
}

@test "dokploy module requires rootful Docker" {
    grep -q 'DOCKER_MODE:-rootful' "$PROJECT_DIR/modules/14-dokploy.sh"
}

@test "ufw-docker module allows routed 80/443 in rootful mode" {
    grep -q 'ufw route allow proto tcp' "$PROJECT_DIR/modules/05-ufw-docker-rules.sh"
}

@test "fail2ban jail matches sshd-session logs and key-only failures" {
    grep -q '_COMM=sshd-session' "$PROJECT_DIR/modules/06-fail2ban.sh"
    grep -q 'filter = sshd\[mode=aggressive\]' "$PROJECT_DIR/modules/06-fail2ban.sh"
}

@test "logwatch module keeps postfix on loopback" {
    grep -q 'Local only' "$PROJECT_DIR/modules/09-logwatch.sh"
}

# Runs install_rootful from the real module with the system commands mocked.
# Args: $1 = docker active before install (0|1), $2 = existing daemon.json content (optional)
# Writes calls to $TEST_TMP/calls.log; daemon.json lives in $TEST_TMP/docker/.
run_rootful_install() {
    local active="$1" existing="${2:-}"
    export DOCKER_DAEMON_JSON="$TEST_TMP/docker/daemon.json"
    export CALLS_LOG="$TEST_TMP/calls.log"
    : > "$CALLS_LOG"
    mkdir -p "$TEST_TMP/docker"
    rm -f "$DOCKER_DAEMON_JSON"
    [[ -n "$existing" ]] && printf '%s' "$existing" > "$DOCKER_DAEMON_JSON"
    export MOCK_DOCKER_ACTIVE="$active"
    run bash -c '
        export NO_COLOR=1
        source "$1"
        setup_docker_repo() { echo "setup_docker_repo" >> "$CALLS_LOG"; }
        apt_install() {
            if [[ -f "$DOCKER_DAEMON_JSON" ]]; then echo "json_present_at_install" >> "$CALLS_LOG"; fi
            echo "apt_install $*" >> "$CALLS_LOG"
        }
        systemctl() {
            echo "systemctl $*" >> "$CALLS_LOG"
            if [[ "${1:-} ${2:-} ${3:-}" == "is-active --quiet docker.service" ]]; then return $((1 - MOCK_DOCKER_ACTIVE)); fi
            return 0
        }
        id() { return 0; }
        usermod() { echo "usermod $*" >> "$CALLS_LOG"; }
        install_rootful
    ' -- "$PROJECT_DIR/modules/12-docker-engine.sh"
}

@test "rootful install on a fresh host installs packages, writes log config first, and does not restart" {
    run_rootful_install 0
    [[ $status -eq 0 ]]
    grep -qx "apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" "$CALLS_LOG"
    # daemon.json must exist before the packages start the daemon
    grep -qx "json_present_at_install" "$CALLS_LOG"
    grep -q '"max-size": "10m"' "$DOCKER_DAEMON_JSON"
    grep -qx "systemctl enable --now containerd.service docker.service" "$CALLS_LOG"
    grep -qx "usermod -aG docker docker" "$CALLS_LOG"
    ! grep -q "systemctl restart" "$CALLS_LOG"
}

@test "rootful install restarts a running daemon after writing a new log config" {
    run_rootful_install 1
    [[ $status -eq 0 ]]
    grep -q '"max-size": "10m"' "$DOCKER_DAEMON_JSON"
    grep -qx "systemctl restart docker.service" "$CALLS_LOG"
    # the restart must come after the daemon is enabled
    local enable_line restart_line
    enable_line=$(grep -n "systemctl enable --now" "$CALLS_LOG" | cut -d: -f1)
    restart_line=$(grep -n "systemctl restart" "$CALLS_LOG" | cut -d: -f1)
    [[ "$restart_line" -gt "$enable_line" ]]
}

@test "rootful install keeps an existing daemon.json and does not restart" {
    run_rootful_install 1 '{"debug": true}'
    [[ $status -eq 0 ]]
    [[ "$(cat "$DOCKER_DAEMON_JSON")" == '{"debug": true}' ]]
    [[ "$output" == *"leaving it unchanged"* ]]
    ! grep -q "systemctl restart" "$CALLS_LOG"
    grep -qx "systemctl enable --now containerd.service docker.service" "$CALLS_LOG"
}

@test "module 12 main rejects an invalid DOCKER_MODE and skips for none" {
    run bash -c 'export NO_COLOR=1; source "$1"; require_root() { :; }; DOCKER_MODE=bogus; main' -- "$PROJECT_DIR/modules/12-docker-engine.sh"
    [[ $status -ne 0 ]]
    [[ "$output" == *"Invalid DOCKER_MODE"* ]]
    run bash -c 'export NO_COLOR=1; source "$1"; require_root() { :; }; DOCKER_MODE=none; main' -- "$PROJECT_DIR/modules/12-docker-engine.sh"
    [[ $status -eq 0 ]]
    [[ "$output" == *"skipped"* ]]
}

# --- setup.sh: --from flag parsing ---

@test "setup.sh accepts --help without requiring root" {
    run bash "$PROJECT_DIR/setup.sh" --help
    [[ $status -eq 0 ]]
    [[ "$output" == *"--from"* ]]
}

@test "setup.sh rejects --from with non-numeric value" {
    run bash "$PROJECT_DIR/setup.sh" --from foo
    [[ $status -ne 0 ]]
    [[ "$output" == *"positive integer"* ]]
}

@test "setup.sh rejects --from 0" {
    run bash "$PROJECT_DIR/setup.sh" --from 0
    [[ $status -ne 0 ]]
    [[ "$output" == *"positive integer"* ]]
}

@test "setup.sh rejects --from with missing value" {
    run bash "$PROJECT_DIR/setup.sh" --from
    [[ $status -ne 0 ]]
    [[ "$output" == *"requires a value"* ]]
}

@test "setup.sh --help documents Docker mode and optional tools" {
    run bash "$PROJECT_DIR/setup.sh" --help
    [[ $status -eq 0 ]]
    [[ "$output" == *"--docker-mode"* ]]
    [[ "$output" == *"--coolify"* ]]
    [[ "$output" == *"--lazydocker"* ]]
    [[ "$output" == *"--dokploy"* ]]
}

@test "setup.sh rejects an invalid Docker mode" {
    run bash "$PROJECT_DIR/setup.sh" --docker-mode bogus
    [[ $status -ne 0 ]]
    [[ "$output" == *"Invalid Docker mode"* ]]
}
