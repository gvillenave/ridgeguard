#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_root

AFTER_RULES="/etc/ufw/after.rules"
MARKER="# BEGIN UFW AND DOCKER"

add_docker_chain_rules() {
    if grep -q "$MARKER" "$AFTER_RULES" 2>/dev/null; then
        info "UFW Docker rules already present, skipping"
        return 0
    fi

    info "Adding Docker-compatible UFW rules..."

    backup_file "$AFTER_RULES"

    cat >> "$AFTER_RULES" << 'EOF'

# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP
-A DOCKER-USER -i docker0 -o docker0 -j ACCEPT

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16

-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 192.168.0.0/16

-A DOCKER-USER -j RETURN

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END UFW AND DOCKER
EOF

    info "Reloading UFW..."
    ufw reload
}

add_docker_chain_rules

# Docker publishes ports through DNAT, so the DOCKER-USER chain above drops
# inbound traffic to containers unless a route rule allows it. Ports 80 and 443
# are open on the host; open them for published containers too (reverse proxies
# such as Traefik/Caddy used by Coolify). Rules match the container port.
if [[ "${DOCKER_MODE:-rootful}" == "rootful" ]]; then
    route_ports=(80 443)
    if [[ "${COOLIFY_PREP:-0}" == "1" ]]; then
        # Coolify dashboard (host 8000 -> container 8080), realtime, terminal
        route_ports+=(8080 6001 6002)
    fi
    for port in "${route_ports[@]}"; do
        info "UFW: allowing routed traffic to container port ${port}/tcp"
        ufw route allow proto tcp from any to any port "$port"
    done
fi

success "UFW Docker rules applied"
