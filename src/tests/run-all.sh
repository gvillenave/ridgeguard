#!/usr/bin/env bash
# Run all tests: shellcheck, BATS unit tests, and Docker integration tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FAILURES=0

run_section() {
    echo ""
    echo "========================================"
    echo "  $1"
    echo "========================================"
    echo ""
}

# --- ShellCheck ---
run_section "ShellCheck Linting"

if command -v shellcheck &>/dev/null; then
    if bash "$SCRIPT_DIR/shellcheck.sh"; then
        echo ""
        echo "ShellCheck: PASSED"
    else
        echo ""
        echo "ShellCheck: FAILED"
        FAILURES=$((FAILURES + 1))
    fi
else
    echo "shellcheck not installed — install with: apt-get install shellcheck"
    FAILURES=$((FAILURES + 1))
fi

# --- BATS Unit Tests ---
run_section "BATS Unit Tests"

if command -v bats &>/dev/null; then
    if bats "$SCRIPT_DIR/unit/"*.bats; then
        echo ""
        echo "BATS: PASSED"
    else
        echo ""
        echo "BATS: FAILED"
        FAILURES=$((FAILURES + 1))
    fi
else
    echo "bats not installed — install with: apt-get install bats"
    FAILURES=$((FAILURES + 1))
fi

# --- Docker Integration Tests ---
run_section "Docker Integration Tests"

if command -v docker &>/dev/null; then
    echo "Building test image..."
    if docker build -t ridgeguard-test -f "$SCRIPT_DIR/integration/Dockerfile" "$PROJECT_DIR" 2>&1; then
        echo ""
        echo "Running integration tests..."
        if docker run --rm ridgeguard-test; then
            echo "Integration: PASSED"
        else
            echo "Integration: FAILED"
            FAILURES=$((FAILURES + 1))
        fi
    else
        echo "Integration: FAILED (build error)"
        FAILURES=$((FAILURES + 1))
    fi
else
    echo "Docker not available — skipping integration tests"
    echo "Run integration tests with: docker build -t ridgeguard-test -f tests/integration/Dockerfile . && docker run --rm ridgeguard-test"
fi

# --- Penetration Tests ---
run_section "Penetration Tests"

if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    echo "Running pentest suite (attacker + target containers)..."
    PENTEST_DIR="$SCRIPT_DIR/pentest"
    if (cd "$PENTEST_DIR" && docker compose up --build --abort-on-container-exit --exit-code-from attacker 2>&1); then
        echo "Pentest: PASSED"
    else
        echo "Pentest: FAILED"
        FAILURES=$((FAILURES + 1))
    fi
    (cd "$PENTEST_DIR" && docker compose down -v 2>/dev/null) || true
else
    echo "Docker Compose not available — skipping penetration tests"
    echo "Run with: cd tests/pentest && docker compose up --build --abort-on-container-exit --exit-code-from attacker"
fi

# --- Summary ---
echo ""
echo "========================================"
if [[ $FAILURES -eq 0 ]]; then
    echo "  All test suites passed!"
else
    echo "  $FAILURES test suite(s) failed"
fi
echo "========================================"

exit "$FAILURES"
