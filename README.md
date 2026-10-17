# RidgeGuard

Automated toolset for bootstrapping a fresh Ubuntu 26.04 server with security hardening and Docker (rootful by default, rootless optional). It prepares the server for a PaaS manager such as Coolify.

## What It Does

| Step | Module | Description |
|------|--------|-------------|
| 01 | system-update | Runs `apt update && apt upgrade` |
| 02 | ssh-key-setup | Prompts for SSH public key if `authorized_keys` is empty |
| 03 | ssh-hardening | Disables password auth, enables pubkey, disables PAM, allows root |
| 04 | ufw-setup | Enables UFW with deny-by-default, allows ports 22, 80, 443 |
| 05 | ufw-docker-rules | Adds Docker-compatible iptables rules to UFW |
| 06 | fail2ban | Installs fail2ban with SSH jail protection |
| 07 | sysctl-hardening | Hardens kernel network parameters (SYN cookies, anti-spoofing, etc.) |
| 08 | unattended-upgrades | Enables automatic Ubuntu security updates |
| 09 | logwatch | Installs logwatch (postfix bound to loopback) and auditd for log monitoring |
| 10 | ssh-restart | Restarts the SSH service |
| 11 | docker-user | Creates a `docker` user with sudo privileges |
| 12 | docker-engine | Installs Docker Engine in rootful (default) or rootless mode, or skips it |
| 13 | lazydocker | *(optional)* Installs lazydocker for terminal-based container management |
| 14 | dokploy | *(optional)* Installs Dokploy self-hosted PaaS |
| 15 | verify | Checks all services and prints a status report |

## Prerequisites

- Fresh Ubuntu 26.04 LTS (or later) server. Other releases are refused unless `RIDGEGUARD_ALLOW_UNSUPPORTED_OS=1` is set.
- Root access via SSH
- Active SSH connection

## Installation

### From .deb package

Download the latest `.deb` from [GitHub Releases](https://github.com/cedarcipher/ridgeguard/releases) and install:

```bash
sudo dpkg -i ridgeguard_*.deb
sudo ridgeguard
```

### From source

```bash
git clone https://github.com/cedarcipher/ridgeguard.git
cd ridgeguard/src
sudo bash setup.sh
```

## Quick Start

```bash
sudo bash setup.sh
```

The default setup installs rootful Docker. The script asks whether to install the optional tools (Dokploy, lazydocker). Both default to "no". Without a TTY, both are skipped. Flags override the prompts:

```bash
sudo bash setup.sh --dokploy --lazydocker     # include both optional tools
sudo bash setup.sh --no-dokploy --no-lazydocker
```

### Prepare a server for Coolify

```bash
sudo bash setup.sh --coolify
```

Then install Coolify with its official installer. `--coolify` does this:

- Forces rootful Docker (Coolify does not support rootless Docker).
- Opens ports 8000, 6001 and 6002 (dashboard, realtime, terminal) in UFW.
- Keeps root SSH login with keys only, which Coolify uses to manage the server.
- Cannot be combined with `--dokploy`.

After you set a domain for Coolify, close the extra ports:

```bash
sudo ufw delete allow 8000/tcp
sudo ufw delete allow 6001/tcp
sudo ufw delete allow 6002/tcp
sudo ufw route delete allow proto tcp from any to any port 8080
sudo ufw route delete allow proto tcp from any to any port 6001
sudo ufw route delete allow proto tcp from any to any port 6002
```

### Docker modes

| Flag | Mode | Notes |
|------|------|-------|
| *(default)*, `--rootful` | Rootful | System-wide daemon. Needed for Coolify and Dokploy. |
| `--rootless` | Rootless | Daemon runs as the `docker` user. Not compatible with Coolify or Dokploy. |
| `--no-docker` | None | Skip Docker. Hardening only. |

You can also set `DOCKER_MODE=rootful|rootless|none` in the environment.

## Resume From a Step

If the setup was interrupted or a step failed, resume from any step:

```bash
sudo bash setup.sh --from 6
```

## Run Individual Modules

Each module can be run standalone:

```bash
sudo bash modules/04-ufw-setup.sh
```

## What Gets Configured

**Firewall (UFW):**
- Default: deny incoming, allow outgoing
- Open ports: 22 (SSH), 80 (HTTP), 443 (HTTPS)
- Docker-compatible rules via ufw-docker

**SSH (`/etc/ssh/sshd_config`):**
- Password authentication: disabled
- Public key authentication: enabled
- PAM: disabled
- Root login: allowed (key-only)

**Fail2ban:**
- SSH jail with 1h ban, 3 max retries in 10m window
- Uses systemd backend, aggressive filter mode, and matches the `sshd-session` process (OpenSSH 9.8+), so key-only failures are counted

**Kernel (sysctl):**
- SYN flood protection enabled
- ICMP redirects disabled
- Source routing disabled
- Reverse path filtering enabled
- Martian packet logging enabled

**Docker (rootful, default):**
- System-wide Docker Engine from Docker's official apt repository
- Container log rotation in `/etc/docker/daemon.json` (an existing file is not changed)
- The `docker` user joins the `docker` group
- UFW routes ports 80 and 443 to containers, so a reverse proxy (Traefik, Caddy) works

**Docker (rootless, `--rootless`):**
- Installed under the `docker` user
- System Docker daemon disabled
- Starts automatically on boot via linger
- If Docker is already installed in root mode, prompts to reinstall in rootless mode or skip

**lazydocker (optional):**
- Terminal UI for Docker, installed only on request

**Dokploy (optional):**
- Self-hosted PaaS (alternative to Heroku/Vercel/Netlify)
- Needs rootful Docker. Setup refuses `--dokploy` with `--rootless`
- Runs on Docker Swarm, deployed via official install script
- Dashboard accessible on port 3000
- UFW automatically opens port 3000 when enabled

## Post-Setup

SSH into the server as the docker user:
```bash
ssh docker@your-server-ip
```

Run Docker containers (no sudo needed in rootless mode; in rootful mode the `docker` user is in the `docker` group):
```bash
docker run --rm hello-world
docker compose up -d
```

Docker bypasses normal UFW input rules for published ports. Ridgeguard blocks inbound traffic to containers by default. To expose a container port, match the port inside the container:
```bash
sudo ufw route allow proto tcp from any to any port 8080
```

## Testing

The toolset includes four testing layers:

**Run all tests:**
```bash
bash tests/run-all.sh
```

**Individual test suites:**
```bash
# ShellCheck linting (requires: apt install shellcheck)
bash tests/shellcheck.sh

# BATS unit tests (requires: apt install bats)
bats tests/unit/*.bats

# Docker integration tests (requires: docker)
docker build -t ridgeguard-test -f tests/integration/Dockerfile .
docker run --rm ridgeguard-test

# Penetration tests (requires: docker compose)
cd tests/pentest
docker compose up --build --abort-on-container-exit --exit-code-from attacker
docker compose down -v

# Penetration tests with Dokploy enabled
DOKPLOY_ENABLED=1 docker compose up --build --abort-on-container-exit --exit-code-from attacker
```

| Layer | What it tests | Prerequisites |
|-------|--------------|---------------|
| ShellCheck | Syntax, quoting, bash pitfalls | `shellcheck` |
| BATS | `lib/common.sh` functions, module logic, key validation, idempotency | `bats` |
| Docker | Real module execution in an Ubuntu container | `docker` |
| Pentest | SSH attacks, port scanning, privilege escalation, config audit | `docker compose` |

### Penetration Tests

The pentest suite uses two containers (attacker + target) connected via a Docker network:

- **Target**: systemd-enabled Ubuntu 26.04 with all hardening modules applied (rootful Docker routing rules, no Docker daemon)
- **Attacker**: Probes the target with nmap, sshpass, and SSH to verify hardening works

Test categories:
- **SSH attacks**: password rejection, key auth, wrong key rejection, fail2ban brute force detection
- **Network/firewall**: port scanning (only 22/80/443 open, +3000 with Dokploy), blocked ports filtered, UFW policies
- **Privilege escalation**: sudo access control, file permissions, SUID audit, user isolation
- **Config audit**: sysctl params, sshd settings, service status, audit rules, listening services, Dokploy checks
