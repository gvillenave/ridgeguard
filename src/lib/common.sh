#!/usr/bin/env bash
# Shared library for ridgeguard modules

# Path resolution
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$LIB_DIR")"
export PROJECT_ROOT

# Default Docker user (can be overridden via environment)
DOCKER_USER="${DOCKER_USER:-docker}"
export DOCKER_USER

# Color support (respects NO_COLOR convention)
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

info()    { echo -e "${BLUE}[INFO]${RESET} $*" >&2; }
success() { echo -e "${GREEN}[OK]${RESET} $*" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*" >&2; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

step() {
    local num="$1" total="$2" desc="$3"
    echo -e "\n${BOLD}==> [Step ${num}/${total}] ${desc}${RESET}" >&2
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

command_exists() {
    command -v "$1" &>/dev/null
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup
        backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
        cp "$file" "$backup"
        info "Backed up $file -> $backup"
    fi
}

# Safely set an sshd_config directive (uncomment or append)
set_sshd_option() {
    local key="$1" value="$2" file="${3:-/etc/ssh/sshd_config}"

    # Escape key for sed ERE pattern side (all ERE metacharacters)
    # ] first (literal when immediately after [), [ second, \ separates [ from .
    # to avoid BSD sed interpreting [. as a POSIX collating element
    local esc_key
    esc_key=$(printf '%s' "$key" | sed 's/[][\\.()*^$+?{}|/]/\\&/g')

    # Escape full replacement line for sed replacement side (& / \ are special)
    local esc_repl
    esc_repl=$(printf '%s' "${key} ${value}" | sed 's/[&/\\]/\\&/g')

    if grep -qE "^\s*${esc_key}\s+" "$file" 2>/dev/null; then
        sed -E -i.bak "s/^[[:space:]]*${esc_key}[[:space:]].*/${esc_repl}/" "$file" && rm -f "${file}.bak"
    elif grep -qE "^#\s*${esc_key}\s+" "$file" 2>/dev/null; then
        sed -E -i.bak "s/^#[[:space:]]*${esc_key}[[:space:]].*/${esc_repl}/" "$file" && rm -f "${file}.bak"
    else
        echo "${key} ${value}" >> "$file"
    fi
}

# apt-get install with retry logic for transient mirror failures
apt_install() {
    local max_retries=3
    local delay=5
    local attempt
    for attempt in $(seq 1 "$max_retries"); do
        if apt-get install -y "$@"; then
            return 0
        fi
        if [[ $attempt -lt $max_retries ]]; then
            warn "apt-get install failed (attempt $attempt/$max_retries), refreshing indexes and retrying in ${delay}s..."
            sleep "$delay"
            apt-get update -y >/dev/null 2>&1 || true
            delay=$((delay * 2))
        fi
    done
    error "apt-get install failed after $max_retries attempts"
    return 1
}
