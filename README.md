# RidgeGuard

Automated toolset for bootstrapping a fresh Ubuntu server with security hardening and Docker in rootless mode.

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
| 09 | logwatch | Installs logwatch and auditd for log monitoring |
| 10 | ssh-restart | Restarts the SSH service |
| 11 | docker-user | Creates a `docker` user with sudo privileges |
| 12 | docker-engine | Installs Docker Engine in rootless mode (detects existing root-mode) |
| 13 | lazydocker | Installs lazydocker for terminal-based container management |
| 14 | dokploy | *(optional)* Installs Dokploy self-hosted PaaS |
| 15 | verify | Checks all services and prints a status report |

## Prerequisites

- Fresh Ubuntu 24.04 LTS+ server
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
cd ridgeguard
sudo bash setup.sh
```

## Quick Start

```bash
sudo bash setup.sh
```

You will be prompted whether to install Dokploy (a self-hosted PaaS). To skip the prompt:

```bash
sudo bash setup.sh --dokploy      # include Dokploy
sudo bash setup.sh --no-dokploy   # skip Dokploy
```

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
- SSH jail with 1h ban, 5 max retries in 10m window
- Uses systemd backend

**Kernel (sysctl):**
- SYN flood protection enabled
- ICMP redirects disabled
- Source routing disabled
- Reverse path filtering enabled
- Martian packet logging enabled

**Docker:**
- Installed in rootless mode under the `docker` user
- System Docker daemon disabled
- Starts automatically on boot via linger
- lazydocker installed for terminal-based container management
- If Docker is already installed in root mode, prompts to reinstall in rootless mode or skip

**Dokploy (optional):**
- Self-hosted PaaS (alternative to Heroku/Vercel/Netlify)
- Runs on Docker Swarm, deployed via official install script
- Dashboard accessible on port 3000
- UFW automatically opens port 3000 when enabled

## Post-Setup

SSH into the server as the docker user:
```bash
ssh docker@your-server-ip
```

Run Docker containers (no sudo needed):
```bash
docker run --rm hello-world
docker compose up -d
```

To expose a Docker container port through UFW:
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

- **Target**: systemd-enabled Ubuntu with all hardening modules applied
- **Attacker**: Probes the target with nmap, sshpass, and SSH to verify hardening works

Test categories:
- **SSH attacks**: password rejection, key auth, wrong key rejection, fail2ban brute force detection
- **Network/firewall**: port scanning (only 22/80/443 open, +3000 with Dokploy), blocked ports filtered, UFW policies
- **Privilege escalation**: sudo access control, file permissions, SUID audit, user isolation
- **Config audit**: sysctl params, sshd settings, service status, audit rules, listening services, Dokploy checks
