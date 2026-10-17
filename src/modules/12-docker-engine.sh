#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

DOCKER_MODE="${DOCKER_MODE:-rootful}"
DOCKER_DAEMON_JSON="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"

setup_docker_repo() {
    # Install prerequisites
    apt_install ca-certificates curl gnupg
    if [[ "$DOCKER_MODE" == "rootless" ]]; then
        apt_install uidmap dbus-user-session
    fi

    # Add Docker's official GPG key and repository
    DOCKER_GPG="/etc/apt/keyrings/docker.gpg"
    DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

    # Download key to a temp file first, verify fingerprint, then install atomically
    verify_docker_gpg() {
        local keyfile="$1"
        local pub_count primary_fp

        # Ensure exactly one primary public key and matching fingerprint
        read -r pub_count primary_fp < <(
            gpg --no-default-keyring --keyring "$keyfile" \
                --fingerprint --with-colons 2>/dev/null | \
            awk -F: '
                $1 == "pub" { pub_count++; capture = (pub_count == 1); next }
                $1 == "fpr" && capture && primary_fp == "" { primary_fp = $10; next }
                END { if (pub_count > 0) print pub_count, primary_fp }
            '
        )

        if [[ -z "$pub_count" || "$pub_count" -ne 1 || "$primary_fp" != "$DOCKER_GPG_FINGERPRINT" ]]; then
            error "Docker GPG key fingerprint mismatch or unexpected keyring contents!"
            error "  Expected fingerprint: $DOCKER_GPG_FINGERPRINT"
            error "  Found pub keys:       ${pub_count:-0}"
            error "  Primary fingerprint:  ${primary_fp:-<none>}"
            return 1
        fi
    }

    if [[ ! -f "$DOCKER_GPG" ]]; then
        install -m 0755 -d /etc/apt/keyrings
        tmp_gpg="$(mktemp /etc/apt/keyrings/.docker.gpg.XXXXXX)"
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o "$tmp_gpg"
        if verify_docker_gpg "$tmp_gpg"; then
            mv "$tmp_gpg" "$DOCKER_GPG"
            chmod a+r "$DOCKER_GPG"
            info "Docker GPG key installed and verified (fingerprint OK)"
        else
            rm -f "$tmp_gpg"
            exit 1
        fi
    else
        # Verify pre-existing key hasn't been corrupted or replaced
        if ! verify_docker_gpg "$DOCKER_GPG"; then
            error "Pre-existing Docker GPG key failed verification, removing"
            rm -f "$DOCKER_GPG"
            exit 1
        fi
        info "Docker GPG key already present (fingerprint OK)"
    fi

    DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
    if [[ ! -f "$DOCKER_LIST" ]]; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=$DOCKER_GPG] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > "$DOCKER_LIST"
        apt-get update -y
        info "Docker repository added"
    fi
}

install_rootful() {
    info "Installing Docker Engine in rootful (system-wide) mode..."
    setup_docker_repo

    # Rotate container logs so a chatty container cannot fill the disk.
    # Write the file before the install so a fresh daemon starts with it.
    # Keep an existing daemon.json untouched.
    local daemon_json="$DOCKER_DAEMON_JSON" daemon_json_created=0 docker_was_active=0
    if systemctl is-active --quiet docker.service 2>/dev/null; then
        docker_was_active=1
    fi
    if [[ ! -f "$daemon_json" ]]; then
        install -m 0755 -d "$(dirname "$daemon_json")"
        cat > "$daemon_json" << 'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON
        daemon_json_created=1
        info "Wrote $daemon_json (log rotation)"
    else
        info "$daemon_json already exists, leaving it unchanged"
    fi

    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable --now containerd.service docker.service

    # A daemon that was already running does not read the new file until restart.
    # Existing containers keep their old log settings until recreated.
    if [[ $daemon_json_created -eq 1 && $docker_was_active -eq 1 ]]; then
        info "Restarting Docker to apply log rotation..."
        systemctl restart docker.service
    fi

    # Lets the docker user run docker (and lazydocker) without sudo.
    # The user already has passwordless sudo, so this grants no new privilege.
    if id "$DOCKER_USER" &>/dev/null; then
        usermod -aG docker "$DOCKER_USER"
        info "Added '$DOCKER_USER' to the docker group"
    fi

    success "Docker Engine installed in rootful mode"
}

install_rootless() {
    # Detect existing root-mode Docker installation (service, socket unit, or leftover socket)
    if systemctl is-active --quiet docker.service 2>/dev/null || \
       systemctl is-active --quiet docker.socket 2>/dev/null || \
       [[ -S /var/run/docker.sock ]]; then
        warn "Docker appears to be installed in root (system-wide) mode, or a leftover /var/run/docker.sock was found."
        warn "Rootless mode requires that the system-wide Docker daemon is not running."
        echo >&2
        echo -e "${BOLD}Options:${RESET}" >&2
        echo "  1) Configure Docker in rootless mode (stops system daemon; does NOT migrate existing images/containers)" >&2
        echo "  2) Skip this step (keep current root-mode Docker)" >&2
        echo >&2
        if [[ -r /dev/tty ]]; then
            read -rp "Choose [1/2] (default: 2 = skip): " docker_choice </dev/tty
        else
            warn "No TTY available; defaulting to skip Docker rootless setup (option 2)."
            docker_choice=2
        fi
        case "${docker_choice:-2}" in
            1)
                info "Proceeding with rootless mode installation..."
                ;;
            *)
                info "Skipping Docker rootless setup, keeping existing root-mode installation."
                exit 0
                ;;
        esac
    fi

    info "Installing Docker Engine in rootless mode..."
    setup_docker_repo
    apt_install docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-ce-rootless-extras

    # Disable system-wide Docker daemon (rootless mode doesn't need it)
    info "Disabling system-wide Docker daemon..."
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl disable --now docker.service docker.socket 2>/dev/null; then
            warn "Failed to disable docker.service/docker.socket via systemctl; verifying status..."
        fi
        if systemctl is-active --quiet docker.service 2>/dev/null || \
           systemctl is-active --quiet docker.socket 2>/dev/null; then
            error "docker.service or docker.socket is still active after disable attempt."
            error "Please stop the root-mode Docker daemon manually before running this module."
            exit 1
        fi
        # Remove leftover socket so dockerd-rootless-setuptool.sh doesn't refuse to run
        if [[ -S /var/run/docker.sock ]]; then
            info "Removing leftover Docker socket at /var/run/docker.sock"
            rm -f /var/run/docker.sock
        fi
    else
        warn "systemctl not available; skipping daemon disable."
        warn "Not removing /var/run/docker.sock because daemon state cannot be verified."
    fi

    # Ensure subuid/subgid entries exist for the docker user
    if ! grep -q "^${DOCKER_USER}:" /etc/subuid 2>/dev/null; then
        usermod --add-subuids 100000-165535 "$DOCKER_USER"
        info "Added subuid range for $DOCKER_USER"
    fi
    if ! grep -q "^${DOCKER_USER}:" /etc/subgid 2>/dev/null; then
        usermod --add-subgids 100000-165535 "$DOCKER_USER"
        info "Added subgid range for $DOCKER_USER"
    fi

    # Enable linger so rootless Docker runs without an active login session
    loginctl enable-linger "$DOCKER_USER"
    info "Linger enabled for $DOCKER_USER"

    # Install rootless Docker as the docker user
    DOCKER_UID="$(id -u "$DOCKER_USER")"
    info "Running rootless Docker setup as '$DOCKER_USER'..."
    sudo -u "$DOCKER_USER" \
        XDG_RUNTIME_DIR="/run/user/$DOCKER_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$DOCKER_UID/bus" \
        dockerd-rootless-setuptool.sh install

    # Enable rootless Docker to start on boot
    sudo -u "$DOCKER_USER" \
        XDG_RUNTIME_DIR="/run/user/$DOCKER_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$DOCKER_UID/bus" \
        systemctl --user enable docker

    success "Docker Engine installed in rootless mode for user '$DOCKER_USER'"
}

main() {
    require_root

    case "$DOCKER_MODE" in
        none)
            info "Docker installation skipped (DOCKER_MODE=none)"
            exit 0
            ;;
        rootful)
            install_rootful
            ;;
        rootless)
            install_rootless
            ;;
        *)
            error "Invalid DOCKER_MODE '$DOCKER_MODE' (expected rootful, rootless, or none)"
            exit 1
            ;;
    esac
}

# Run only when executed; tests source this file to call the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
