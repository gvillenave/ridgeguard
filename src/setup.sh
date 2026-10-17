#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

MODULES_DIR="$SCRIPT_DIR/modules"
START_FROM=1
INSTALL_DOKPLOY="${INSTALL_DOKPLOY:-}"
INSTALL_LAZYDOCKER="${INSTALL_LAZYDOCKER:-}"
COOLIFY_PREP="${COOLIFY_PREP:-0}"

# Parse arguments (before require_root so --help works without root)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)
            if [[ $# -lt 2 ]]; then
                error "--from requires a value"
                exit 1
            fi
            START_FROM="$2"
            shift 2
            ;;
        --from=*)
            START_FROM="${1#*=}"
            shift
            ;;
        --dokploy)
            INSTALL_DOKPLOY=1
            shift
            ;;
        --no-dokploy)
            INSTALL_DOKPLOY=0
            shift
            ;;
        --lazydocker)
            INSTALL_LAZYDOCKER=1
            shift
            ;;
        --no-lazydocker)
            INSTALL_LAZYDOCKER=0
            shift
            ;;
        --docker-mode)
            if [[ $# -lt 2 ]]; then
                error "--docker-mode requires a value"
                exit 1
            fi
            DOCKER_MODE="$2"
            shift 2
            ;;
        --docker-mode=*)
            DOCKER_MODE="${1#*=}"
            shift
            ;;
        --rootful)
            DOCKER_MODE=rootful
            shift
            ;;
        --rootless)
            DOCKER_MODE=rootless
            shift
            ;;
        --no-docker)
            DOCKER_MODE=none
            shift
            ;;
        --coolify)
            COOLIFY_PREP=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--from N] [--docker-mode MODE] [--coolify] [--dokploy|--no-dokploy] [--lazydocker|--no-lazydocker]"
            echo ""
            echo "Options:"
            echo "  --from N          Resume from step N (e.g., --from 6)"
            echo "  --docker-mode M   Docker mode: rootful (default), rootless, or none"
            echo "  --rootful         Same as --docker-mode rootful"
            echo "  --rootless        Same as --docker-mode rootless (not compatible with Coolify/Dokploy)"
            echo "  --no-docker       Same as --docker-mode none"
            echo "  --coolify         Prepare the server for Coolify (rootful Docker, opens ports 8000/6001/6002)"
            echo "  --dokploy         Install Dokploy (optional, self-hosted PaaS)"
            echo "  --no-dokploy      Skip Dokploy installation"
            echo "  --lazydocker      Install lazydocker (optional, terminal UI for Docker)"
            echo "  --no-lazydocker   Skip lazydocker installation"
            echo "  -h, --help        Show this help message"
            echo ""
            echo "Dokploy and lazydocker are asked about interactively when no flag is given."
            echo "Without a TTY they are skipped."
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate START_FROM is a positive integer (strip leading zeros for user convenience)
if ! [[ "$START_FROM" =~ ^[0-9]+$ ]] || (( 10#$START_FROM < 1 )); then
    error "--from requires a positive integer (got: '$START_FROM')"
    exit 1
fi
START_FROM=$((10#$START_FROM))  # normalize leading zeros (e.g., 06 -> 6)

case "$DOCKER_MODE" in
    rootful|rootless|none) ;;
    *)
        error "Invalid Docker mode '$DOCKER_MODE' (expected rootful, rootless, or none)"
        exit 1
        ;;
esac

require_root
check_os

# Collect modules in sorted order
mapfile -t modules < <(find "$MODULES_DIR" -maxdepth 1 -name '[0-9][0-9]-*.sh' | sort)
total=${#modules[@]}

if [[ $total -eq 0 ]]; then
    error "No modules found in $MODULES_DIR"
    exit 1
fi

echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  Ubuntu Server Setup Toolset${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""

# Coolify needs the system-wide Docker daemon
if [[ "$COOLIFY_PREP" == "1" ]]; then
    if [[ "$DOCKER_MODE" != "rootful" ]]; then
        error "--coolify requires rootful Docker (got: $DOCKER_MODE)"
        exit 1
    fi
    if [[ "$INSTALL_DOKPLOY" == "1" ]]; then
        error "--coolify and --dokploy cannot be combined (both are PaaS managers)"
        exit 1
    fi
    INSTALL_DOKPLOY=0
fi

# Prompt for optional components if not specified via flag or environment
if [[ -z "$INSTALL_DOKPLOY" ]]; then
    if [[ "$DOCKER_MODE" != "rootful" ]]; then
        INSTALL_DOKPLOY=0
    else
        echo -e "${BOLD}Optional: Install Dokploy?${RESET}" >&2
        echo "  Dokploy is a self-hosted PaaS (like Heroku/Vercel)." >&2
        echo "  It requires rootful Docker and Docker Swarm, and opens port 3000." >&2
        if ask_yes_no "Install Dokploy?"; then INSTALL_DOKPLOY=1; else INSTALL_DOKPLOY=0; fi
        echo "" >&2
    fi
fi

if [[ "$INSTALL_DOKPLOY" == "1" ]] && [[ "$DOCKER_MODE" != "rootful" ]]; then
    error "Dokploy requires rootful Docker (got: $DOCKER_MODE)"
    exit 1
fi

if [[ -z "$INSTALL_LAZYDOCKER" ]]; then
    if [[ "$DOCKER_MODE" == "none" ]]; then
        INSTALL_LAZYDOCKER=0
    else
        echo -e "${BOLD}Optional: Install lazydocker?${RESET}" >&2
        echo "  lazydocker is a terminal UI for Docker." >&2
        if ask_yes_no "Install lazydocker?"; then INSTALL_LAZYDOCKER=1; else INSTALL_LAZYDOCKER=0; fi
        echo "" >&2
    fi
fi
export INSTALL_DOKPLOY INSTALL_LAZYDOCKER COOLIFY_PREP DOCKER_MODE

info "Found $total modules. Starting from step $START_FROM."
info "Docker mode: $DOCKER_MODE"
[[ "$COOLIFY_PREP" == "1" ]] && info "Server will be prepared for Coolify."
if [[ "$INSTALL_DOKPLOY" == "1" ]]; then
    info "Dokploy will be installed."
else
    info "Dokploy will be skipped."
fi
if [[ "$INSTALL_LAZYDOCKER" == "1" ]]; then
    info "lazydocker will be installed."
else
    info "lazydocker will be skipped."
fi
echo ""

declare -A results

for module in "${modules[@]}"; do
    module_name="$(basename "$module")"
    # Extract step number from filename (e.g., "01" from "01-system-update.sh")
    step_num="${module_name%%-*}"
    step_num=$((10#$step_num))  # Remove leading zero

    if [[ $step_num -lt $START_FROM ]]; then
        results["$module_name"]="SKIPPED"
        continue
    fi

    # Skip optional modules the user did not select
    if [[ "$module_name" == *"dokploy"* ]] && [[ "$INSTALL_DOKPLOY" != "1" ]]; then
        results["$module_name"]="SKIPPED"
        continue
    fi
    if [[ "$module_name" == *"lazydocker"* ]] && [[ "$INSTALL_LAZYDOCKER" != "1" ]]; then
        results["$module_name"]="SKIPPED"
        continue
    fi
    if [[ "$module_name" == *"docker-engine"* ]] && [[ "$DOCKER_MODE" == "none" ]]; then
        results["$module_name"]="SKIPPED"
        continue
    fi

    # Build a human-readable description from the filename
    desc="${module_name%.sh}"
    desc="${desc#[0-9][0-9]-}"
    desc="${desc//-/ }"

    step "$step_num" "$total" "$desc"

    while true; do
        if bash "$module"; then
            success "$module_name completed"
            results["$module_name"]="OK"
            break
        else
            error "$module_name failed"
            results["$module_name"]="FAILED"

            echo "" >&2
            echo -e "${YELLOW}What would you like to do?${RESET}" >&2
            echo "  [C] Continue to next module" >&2
            echo "  [R] Retry this module" >&2
            echo "  [A] Abort setup" >&2

            while true; do
                read -r -p "Choice [C/R/A]: " choice < /dev/tty
                case "${choice,,}" in
                    c)
                        warn "Skipping $module_name, continuing..."
                        break 2
                        ;;
                    r)
                        info "Retrying $module_name..."
                        break
                        ;;
                    a)
                        error "Setup aborted by user"
                        exit 1
                        ;;
                    *)
                        echo "Please enter C, R, or A" >&2
                        ;;
                esac
            done
        fi
    done
done

# Print summary
echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  Setup Summary${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""

for module in "${modules[@]}"; do
    module_name="$(basename "$module")"
    status="${results[$module_name]:-UNKNOWN}"
    case "$status" in
        OK)      echo -e "  ${GREEN}✓${RESET} $module_name" ;;
        FAILED)  echo -e "  ${RED}✗${RESET} $module_name" ;;
        SKIPPED) echo -e "  ${YELLOW}–${RESET} $module_name (skipped)" ;;
        *)       echo -e "  ? $module_name" ;;
    esac
done

echo ""
success "Setup complete!"
