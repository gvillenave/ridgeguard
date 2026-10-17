#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

INSTALL_DIR="/usr/local/bin"

# This module is optional: skip unless INSTALL_LAZYDOCKER=1
if [[ "${INSTALL_LAZYDOCKER:-0}" != "1" ]]; then
    info "lazydocker installation skipped (not selected)"
    exit 0
fi

info "Installing lazydocker..."

# Determine latest release version from GitHub
LAZYDOCKER_VERSION=$(curl -fsSL "https://api.github.com/repos/jesseduffield/lazydocker/releases/latest" \
    | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')

if [[ -z "$LAZYDOCKER_VERSION" ]]; then
    error "Could not determine latest lazydocker version"
    exit 1
fi

# Validate version format to guard against malformed API responses
if ! [[ "$LAZYDOCKER_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    error "Extracted lazydocker version '$LAZYDOCKER_VERSION' does not look valid"
    exit 1
fi

# Check if already installed at this version
if command -v lazydocker &>/dev/null; then
    installed_version=$(lazydocker --version 2>/dev/null | grep -oP 'Version:\s*\K[\d.]+' || echo "")
    if [[ "$installed_version" == "$LAZYDOCKER_VERSION" ]]; then
        success "lazydocker $LAZYDOCKER_VERSION is already installed"
        exit 0
    fi
    info "Upgrading lazydocker from $installed_version to $LAZYDOCKER_VERSION"
fi

# Determine architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH="x86_64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="armv6" ;;
    *)       error "Unsupported architecture: $ARCH"; exit 1 ;;
esac

TARBALL="lazydocker_${LAZYDOCKER_VERSION}_Linux_${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/jesseduffield/lazydocker/releases/download/v${LAZYDOCKER_VERSION}/${TARBALL}"

# Download and install
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

info "Downloading lazydocker $LAZYDOCKER_VERSION ($ARCH)..."
curl -fsSL "$DOWNLOAD_URL" -o "$WORK_DIR/$TARBALL"

tar -xzf "$WORK_DIR/$TARBALL" -C "$WORK_DIR"
install -m 755 "$WORK_DIR/lazydocker" "$INSTALL_DIR/lazydocker"

success "lazydocker $LAZYDOCKER_VERSION installed to $INSTALL_DIR/lazydocker"
info "Run 'lazydocker' as the $DOCKER_USER user to manage containers"
