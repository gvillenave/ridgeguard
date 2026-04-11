#!/usr/bin/env bash
# ShellCheck linting for all scripts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

echo "Running ShellCheck..."
echo ""

SCRIPTS=("$PROJECT_DIR"/setup.sh "$PROJECT_DIR"/release.sh "$PROJECT_DIR"/lib/*.sh "$PROJECT_DIR"/modules/*.sh "$PROJECT_DIR"/tests/run-all.sh "$PROJECT_DIR"/tests/integration/run.sh)
# Include pentest scripts if they exist
for pattern in "$PROJECT_DIR"/tests/pentest/lib/*.sh "$PROJECT_DIR"/tests/pentest/attacker/*.sh "$PROJECT_DIR"/tests/pentest/target/*.sh "$PROJECT_DIR"/tests/pentest/tests/*.sh; do
    for f in $pattern; do
        [[ -f "$f" ]] && SCRIPTS+=("$f")
    done
done

for script in "${SCRIPTS[@]}"; do
    name="${script#"$PROJECT_DIR"/}"
    if shellcheck -x -e SC1091 "$script" 2>&1; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo ""
        echo "  ✗ $name"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "ShellCheck: $PASS passed, $FAIL failed"

[[ $FAIL -eq 0 ]]
