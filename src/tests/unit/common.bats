#!/usr/bin/env bats
# Unit tests for lib/common.sh

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_DIR="$(dirname "$(dirname "$TEST_DIR")")"

    # Source common.sh with NO_COLOR to avoid ANSI codes in test output
    export NO_COLOR=1
    source "$PROJECT_DIR/lib/common.sh"
}

# --- Path resolution ---

@test "LIB_DIR is set to the lib directory" {
    [[ "$LIB_DIR" == */lib ]]
}

@test "PROJECT_ROOT is set to the project root" {
    [[ -f "$PROJECT_ROOT/setup.sh" ]]
}

# --- Logging functions ---

@test "info prints to stderr with [INFO] prefix" {
    local result
    result="$(info "test message" 2>&1)"
    [[ "$result" == *"[INFO]"* ]]
    [[ "$result" == *"test message"* ]]
}

@test "success prints to stderr with [OK] prefix" {
    local result
    result="$(success "done" 2>&1)"
    [[ "$result" == *"[OK]"* ]]
    [[ "$result" == *"done"* ]]
}

@test "warn prints to stderr with [WARN] prefix" {
    local result
    result="$(warn "caution" 2>&1)"
    [[ "$result" == *"[WARN]"* ]]
    [[ "$result" == *"caution"* ]]
}

@test "error prints to stderr with [ERROR] prefix" {
    local result
    result="$(error "failed" 2>&1)"
    [[ "$result" == *"[ERROR]"* ]]
    [[ "$result" == *"failed"* ]]
}

@test "step prints step number and description" {
    local result
    result="$(step 3 10 "test step" 2>&1)"
    [[ "$result" == *"[Step 3/10]"* ]]
    [[ "$result" == *"test step"* ]]
}

# --- command_exists ---

@test "command_exists returns 0 for bash" {
    command_exists bash
}

@test "command_exists returns 1 for nonexistent command" {
    ! command_exists this_command_does_not_exist_xyz
}

# --- backup_file ---

@test "backup_file creates a timestamped copy" {
    local tmpfile
    tmpfile="$(mktemp)"
    echo "original" > "$tmpfile"

    backup_file "$tmpfile"

    local backup
    backup="$(find "$(dirname "$tmpfile")" -maxdepth 1 -name "$(basename "$tmpfile").bak.*" | head -1)"
    [[ -f "$backup" ]]
    [[ "$(cat "$backup")" == "original" ]]

    rm -f "$tmpfile" "$backup"
}

@test "backup_file does nothing for nonexistent file" {
    run backup_file "/nonexistent/path/file"
    [[ $status -eq 0 ]]
}

# --- set_sshd_option ---

@test "set_sshd_option sets an existing uncommented option" {
    local tmpfile
    tmpfile="$(mktemp)"
    echo "PasswordAuthentication yes" > "$tmpfile"

    set_sshd_option "PasswordAuthentication" "no" "$tmpfile"

    grep -q "^PasswordAuthentication no$" "$tmpfile"
    rm -f "$tmpfile"
}

@test "set_sshd_option uncomments and sets a commented option" {
    local tmpfile
    tmpfile="$(mktemp)"
    echo "# PasswordAuthentication yes" > "$tmpfile"

    set_sshd_option "PasswordAuthentication" "no" "$tmpfile"

    grep -q "^PasswordAuthentication no$" "$tmpfile"
    rm -f "$tmpfile"
}

@test "set_sshd_option appends option if not present" {
    local tmpfile
    tmpfile="$(mktemp)"
    echo "SomeOtherOption value" > "$tmpfile"

    set_sshd_option "PasswordAuthentication" "no" "$tmpfile"

    grep -q "^PasswordAuthentication no$" "$tmpfile"
    rm -f "$tmpfile"
}

@test "set_sshd_option does not duplicate when already correct" {
    local tmpfile
    tmpfile="$(mktemp)"
    echo "PasswordAuthentication no" > "$tmpfile"

    set_sshd_option "PasswordAuthentication" "no" "$tmpfile"

    local count
    count="$(grep -c "PasswordAuthentication" "$tmpfile")"
    [[ "$count" -eq 1 ]]
    rm -f "$tmpfile"
}

@test "set_sshd_option handles value containing special sed characters" {
    local tmpfile
    tmpfile="$(mktemp)"
    echo "Match key/value" > "$tmpfile"

    set_sshd_option "Match" "user test & group admin" "$tmpfile"

    local count
    count="$(grep -c '^Match ' "$tmpfile")"
    [[ "$count" -eq 1 ]]
    grep -q '^Match user test & group admin$' "$tmpfile"

    rm -f "$tmpfile"
}

# --- require_root ---

@test "require_root succeeds when running as root" {
    if [[ $EUID -ne 0 ]]; then
        skip "not running as root"
    fi
    require_root
}

@test "require_root function contains EUID check" {
    # Verify the function has the right logic (since EUID is readonly in bash)
    declare -f require_root | grep -q 'EUID'
}

# --- check_os ---

@test "check_os accepts Ubuntu 26.04" {
    printf 'ID=ubuntu\nVERSION_ID="26.04"\n' > "$BATS_TEST_TMPDIR/os-release"
    run check_os "$BATS_TEST_TMPDIR/os-release"
    [[ $status -eq 0 ]]
}

@test "check_os accepts Ubuntu newer than 26.04" {
    printf 'ID=ubuntu\nVERSION_ID="26.10"\n' > "$BATS_TEST_TMPDIR/os-release"
    run check_os "$BATS_TEST_TMPDIR/os-release"
    [[ $status -eq 0 ]]
}

@test "check_os rejects Ubuntu 24.04" {
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$BATS_TEST_TMPDIR/os-release"
    run check_os "$BATS_TEST_TMPDIR/os-release"
    [[ $status -ne 0 ]]
    [[ "$output" == *"Unsupported OS"* ]]
}

@test "check_os rejects non-Ubuntu distributions" {
    printf 'ID=debian\nVERSION_ID="13"\n' > "$BATS_TEST_TMPDIR/os-release"
    run check_os "$BATS_TEST_TMPDIR/os-release"
    [[ $status -ne 0 ]]
}

@test "check_os can be overridden with RIDGEGUARD_ALLOW_UNSUPPORTED_OS=1" {
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$BATS_TEST_TMPDIR/os-release"
    RIDGEGUARD_ALLOW_UNSUPPORTED_OS=1 run check_os "$BATS_TEST_TMPDIR/os-release"
    [[ $status -eq 0 ]]
}

@test "DOCKER_MODE defaults to rootful" {
    run bash -c 'unset DOCKER_MODE; source "$1"; echo "$DOCKER_MODE"' -- "$PROJECT_DIR/lib/common.sh"
    [[ "$output" == "rootful" ]]
}
