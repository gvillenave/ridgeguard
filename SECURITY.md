# Security Review & Threat Model

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Security Review: Base Setup (without Dokploy)](#security-review-base-setup-without-dokploy)
4. [Security Review: With Dokploy](#security-review-with-dokploy)
5. [Threat Model](#threat-model)
6. [Recommendations](#recommendations)

---

## Executive Summary

This document provides a security review of the ridgeguard toolset and a threat model for servers deployed with it. The toolset applies 15 modules (13 base hardening + optional Dokploy at module 14 + verification at module 15) to a fresh Ubuntu server. Two deployment profiles are analyzed:

- **Base profile**: Hardened server with rootless Docker (modules 01-13, 15)
- **Dokploy profile**: Base profile + Dokploy self-hosted PaaS (module 14)

**Overall assessment**: The base profile provides a solid security posture for a single-tenant server. The Dokploy profile introduces a meaningful increase in attack surface that requires additional mitigations.

---

## Architecture Overview

```
Internet
    |
    v
[UFW Firewall] -- deny incoming by default
    |
    +-- :22/tcp  --> OpenSSH (key-only, fail2ban protected)
    +-- :80/tcp  --> (available for services)
    +-- :443/tcp --> (available for services)
    +-- :3000/tcp --> Dokploy dashboard (optional)
    |
[Kernel Hardening] -- sysctl: syncookies, rp_filter, no redirects
    |
[Users]
    +-- root      -- SSH key-only login, no password
    +-- docker    -- SSH key-only, passwordless sudo, rootless Docker
    |
[Docker Rootless] -- runs as 'docker' user, no root daemon
    |
[Monitoring]
    +-- fail2ban  -- SSH brute force protection
    +-- auditd    -- file integrity and privilege monitoring
    +-- logwatch  -- daily log summaries
```

---

## Security Review: Base Setup (without Dokploy)

### Strengths

#### S1. SSH Hardening (module 03)
- Password authentication disabled globally, including sshd_config.d drop-ins
- PAM disabled (removes password-based auth vectors entirely)
- Public key authentication enforced
- Configuration validated with `sshd -t` before applying; auto-rollback on failure
- Backups created before modification

#### S2. Firewall (modules 04-05)
- Default deny incoming, allow outgoing
- Only ports 22, 80, 443 exposed
- SSH allowed first to prevent lockout
- Docker-specific UFW rules prevent containers from bypassing the firewall
- DOCKER-USER chain blocks unsolicited inbound to container networks
- Rate-limited logging for blocked Docker traffic

#### S3. Brute Force Protection (module 06)
- fail2ban with SSH jail: 5 retries in 10 minutes, 1-hour ban
- Uses systemd backend (reliable log source)
- Configuration in jail.local (survives package upgrades)

#### S4. Kernel Hardening (module 07)
- SYN flood protection (tcp_syncookies)
- ICMP redirect rejection (IPv4 and IPv6)
- Source routing disabled
- Reverse path filtering (anti-spoofing)
- Martian packet logging
- ICMP broadcast ignore

#### S5. Rootless Docker (module 12)
- System-wide Docker daemon disabled
- Docker runs in user namespace under the `docker` user
- Containers cannot gain host root privileges through Docker socket
- subuid/subgid isolation (100000-165535 range)
- Linger enabled for boot persistence without active session

#### S6. Monitoring and Auditing (module 09)
- auditd watches: /etc/passwd, /etc/shadow, /etc/group, /etc/ssh/sshd_config
- sudo usage logged
- sudoers file changes monitored
- logwatch configured for daily summaries

#### S7. Automatic Updates (module 08)
- unattended-upgrades for security patches
- Reduces window of exposure to known CVEs

### Findings and Weaknesses

#### F1. PermitRootLogin yes (MEDIUM)
**File**: `modules/03-ssh-hardening.sh`
**Issue**: Root login is permitted via SSH. While key-only, a compromised SSH key gives immediate root access with no privilege escalation step required.
**Impact**: Eliminates defense-in-depth. An attacker with a stolen key gets root immediately rather than needing to escalate from an unprivileged user.
**Mitigation**: Set `PermitRootLogin prohibit-password` (functionally equivalent for key auth but blocks root access if password auth is ever re-enabled) or `PermitRootLogin no` and require `sudo` escalation through the docker user.

#### F2. Passwordless sudo for docker user (MEDIUM)
**File**: `modules/11-docker-user.sh`
**Issue**: `docker ALL=(ALL) NOPASSWD:ALL` grants unrestricted passwordless sudo. The docker user is effectively root without any authentication barrier.
**Impact**: Any code execution as the docker user (e.g., via a container escape, application vulnerability, or compromised SSH key) immediately yields full root access.
**Mitigation**: Restrict sudo to specific commands needed for Docker operations, or at minimum require password for destructive operations (`rm`, `dd`, `mkfs`, etc.).

#### F3. SSH keys copied from root to docker user (LOW-MEDIUM)
**File**: `modules/11-docker-user.sh`
**Issue**: Root's authorized_keys are copied verbatim to the docker user. Both accounts share the same authentication credential.
**Impact**: There is no separation of access — anyone who can SSH as root can also SSH as docker, and vice versa. Compromise of one key compromises both accounts.
**Mitigation**: Allow separate key provisioning for each user. Document that operators should use distinct keys for root and docker accounts.

#### F4. Piped curl to shell for lazydocker install (LOW)
**File**: `modules/13-lazydocker.sh`
**Issue**: `curl -fsSL "$DOWNLOAD_URL" | tar -xzf` downloads and extracts a binary from GitHub without verifying checksums or signatures.
**Impact**: A compromised GitHub release, CDN MITM, or DNS hijack could deliver a malicious binary. The binary is installed to `/usr/local/bin` with mode 755 (world-executable).
**Mitigation**: Verify the SHA256 checksum from the GitHub release against the downloaded tarball before installing. lazydocker publishes checksums.txt with each release.

#### F5. No SSH rate limiting at firewall level (LOW)
**File**: `modules/04-ufw-setup.sh`
**Issue**: UFW allows unlimited connection rate to port 22. fail2ban provides application-level rate limiting, but a high-volume SYN flood can still consume resources before fail2ban acts.
**Mitigation**: Add `ufw limit 22/tcp` instead of `ufw allow 22/tcp` to enable connection rate limiting at the firewall level.

#### F6. No MaxAuthTries or LoginGraceTime configured (LOW)
**File**: `modules/03-ssh-hardening.sh`
**Issue**: SSH defaults (MaxAuthTries 6, LoginGraceTime 120s) are used. These are reasonable but could be tightened.
**Mitigation**: Set `MaxAuthTries 3` and `LoginGraceTime 30` to reduce the window for brute force within a single connection.

#### F7. Ports 80 and 443 opened without services (INFO)
**File**: `modules/04-ufw-setup.sh`
**Issue**: Ports 80 and 443 are opened by default even if no web service is running. This is not a vulnerability but increases the attack surface unnecessarily on servers that don't serve HTTP.
**Mitigation**: Consider making web port opening optional or conditional.

#### F8. No IPv6 firewall rules (LOW)
**File**: `modules/04-ufw-setup.sh`
**Issue**: UFW handles IPv6 by default, but the Docker UFW rules in module 05 only cover IPv4 iptables chains. IPv6 Docker traffic may bypass the DOCKER-USER filtering.
**Mitigation**: Add equivalent ip6tables rules in `/etc/ufw/after6.rules`.

#### F9. set_sshd_option regex injection (LOW)
**File**: `lib/common.sh`
**Issue**: The `set_sshd_option` function uses `$key` directly in grep/sed regex patterns. If a key contained regex metacharacters, it could match unintended lines. In practice, all callers use literal SSH directive names, so this is not exploitable in the current codebase.
**Mitigation**: Escape the key parameter with `grep -F` for literal matching.

---

## Security Review: With Dokploy

All findings from the base setup apply. The following are additional concerns specific to the Dokploy deployment profile.

### Additional Attack Surface

#### D1. Piped curl to shell for Dokploy install (HIGH)
**File**: `modules/14-dokploy.sh`
**Issue**: `curl -sSL https://dokploy.com/install.sh | sh` executes arbitrary code from the internet as root. This is the highest-risk pattern in the entire toolset.
**Impact**: Complete server compromise if dokploy.com is compromised, DNS is hijacked, or TLS is intercepted. The install script runs with full root privileges and can modify any system state.
**Mitigation**: Download the script first, review it, verify its checksum against a known-good value, then execute. Pin to a specific Dokploy version. Alternatively, use the manual installation method documented at docs.dokploy.com.

#### D2. Docker Swarm mode replaces rootless Docker (HIGH)
**File**: `modules/14-dokploy.sh`
**Issue**: Dokploy's install script initializes Docker Swarm, which requires the system-wide Docker daemon. This effectively undoes module 12's rootless Docker setup. The Docker daemon runs as root, and containers in Swarm mode have access to the Docker socket.
**Impact**: The security benefit of rootless Docker (S5) is negated. Container escapes can now lead to root compromise. The Docker socket (`/var/run/docker.sock`) becomes a high-value target.
**Mitigation**: Document this trade-off clearly. Consider running Dokploy on a separate server from rootless Docker workloads. Restrict Docker socket access with TLS client certificates.

#### D3. Dokploy dashboard on port 3000 — unauthenticated initial setup (MEDIUM)
**File**: `modules/14-dokploy.sh`
**Issue**: After installation, port 3000 is open to the internet with an unauthenticated setup page. The first person to access it creates the admin account. There is a race condition between installation and the operator setting up authentication.
**Impact**: An attacker scanning for open port 3000 could claim the admin account before the legitimate operator does, gaining full control of the Dokploy instance and all deployed applications.
**Mitigation**: Restrict port 3000 to specific IPs during initial setup, or use UFW to temporarily block 3000 until the admin account is created. Add a post-install reminder to the setup output.

#### D4. Port 3000 exposed permanently (MEDIUM)
**File**: `modules/14-dokploy.sh`
**Issue**: The Dokploy dashboard is exposed on port 3000 without TLS. The admin interface is accessible over plain HTTP.
**Impact**: Credentials and session tokens transmitted in cleartext. Susceptible to MITM attacks on the management interface.
**Mitigation**: Configure a reverse proxy (nginx/Traefik) with TLS termination for the dashboard. Dokploy's built-in Traefik can handle this, but it requires DNS configuration post-install.

#### D5. Dokploy controls the Docker daemon (MEDIUM)
**Issue**: Dokploy has full Docker API access and can run arbitrary containers, mount host volumes, and modify networking. A vulnerability in Dokploy's web interface could lead to arbitrary container execution.
**Impact**: RCE through the Dokploy dashboard leads to full Docker control, which with the system daemon means root-equivalent access.
**Mitigation**: Keep Dokploy updated. Use Dokploy's built-in RBAC. Restrict network access to the dashboard.

### Dokploy vs Base: Comparative Risk Summary

| Aspect | Base Setup | With Dokploy |
|--------|-----------|--------------|
| Open ports | 22, 80, 443 | 22, 80, 443, 3000 |
| Docker mode | Rootless (user namespace) | System daemon (root) |
| Web admin interface | None | Port 3000 (HTTP) |
| Remote code execution surface | SSH only | SSH + Dokploy dashboard |
| Supply chain risk | lazydocker binary | lazydocker + dokploy.com install script |
| Container isolation | User namespace | Root namespace |
| Docker socket exposure | None | Required by Swarm/Dokploy |

---

## Threat Model

### Assets

| Asset | Description | Sensitivity |
|-------|-------------|-------------|
| A1. Server root access | Full system control | Critical |
| A2. SSH private keys | Authentication credentials | Critical |
| A3. Docker workloads | Application containers and data | High |
| A4. Dokploy admin account | PaaS management interface | High (if enabled) |
| A5. Application data | Databases, configs, secrets in containers | High |
| A6. Network position | Server's network access and IP reputation | Medium |

### Threat Actors

| Actor | Capability | Motivation |
|-------|-----------|------------|
| TA1. Opportunistic scanner | Automated scanning, known exploits | Crypto mining, botnet recruitment |
| TA2. Targeted attacker | Custom exploits, social engineering | Data theft, espionage |
| TA3. Insider/key holder | Valid SSH key, legitimate access | Privilege abuse, data exfiltration |
| TA4. Supply chain attacker | Compromise upstream repos/CDNs | Backdoor installation |
| TA5. Network-level attacker | MITM position, DNS hijack | Credential interception, code injection |

### Threat Scenarios

#### T1. SSH Brute Force (TA1)
- **Target**: Port 22
- **Attack**: Automated password/key guessing
- **Mitigations in place**: Password auth disabled, fail2ban (5 retries/1h ban)
- **Residual risk**: LOW — key-only auth makes brute force infeasible
- **Dokploy impact**: No change

#### T2. SSH Key Compromise (TA2, TA3)
- **Target**: A2 (SSH keys) -> A1 (root access)
- **Attack**: Stolen key from operator workstation, leaked in repo, extracted from backup
- **Mitigations in place**: Key-only auth (strong keys are hard to guess)
- **Residual risk**: MEDIUM — a single key grants root (F1) and docker user (F3) access with passwordless sudo (F2). No second factor, no separation.
- **Dokploy impact**: Also grants Dokploy management access through the server

#### T3. Container Escape (TA2)
- **Target**: A3 (Docker workloads) -> A1 (root access)
- **Attack**: Exploit kernel vulnerability or Docker runtime bug to escape container
- **Base mitigations**: Rootless Docker with user namespace isolation
- **Base residual risk**: LOW — user namespace prevents root-on-host even after escape
- **Dokploy mitigations**: System Docker daemon (no rootless)
- **Dokploy residual risk**: HIGH — escape from Swarm container yields host root

#### T4. Dokploy Dashboard Takeover (TA1, TA2)
- **Target**: A4 (Dokploy admin) -> A3, A5 (workloads, data)
- **Attack**: Race condition on initial setup (D3), credential stuffing, session hijacking over HTTP (D4), or exploiting a Dokploy vulnerability (D5)
- **Mitigations in place**: UFW restricts other ports, but 3000 is open
- **Residual risk**: HIGH during initial setup window, MEDIUM afterward
- **Base impact**: N/A (Dokploy not installed)

#### T5. Supply Chain Attack (TA4)
- **Target**: A1 (root access)
- **Attack**: Compromise lazydocker GitHub release (F4) or dokploy.com install script (D1)
- **Base mitigations**: HTTPS for downloads (but no checksum verification)
- **Base residual risk**: LOW — lazydocker is a widely-used Go binary
- **Dokploy residual risk**: MEDIUM — `curl | sh` as root from third-party domain

#### T6. Network-Level Attack (TA5)
- **Target**: A1, A6
- **Attack**: MITM on management traffic, DNS poisoning, ARP spoofing
- **Base mitigations**: SSH uses encrypted channel, sysctl disables ICMP redirects and source routing
- **Base residual risk**: LOW — SSH is resistant to MITM with host key verification
- **Dokploy residual risk**: MEDIUM — dashboard on port 3000 uses HTTP (D4), credentials in cleartext

#### T7. Kernel Exploit (TA2)
- **Target**: A1 (root access)
- **Attack**: Exploit unpatched kernel vulnerability from user-space or container
- **Mitigations in place**: unattended-upgrades for automatic patching, sysctl hardening reduces some attack surface
- **Residual risk**: LOW-MEDIUM — automatic updates reduce window, but zero-days remain a risk
- **Dokploy impact**: Higher risk due to more services running as root

#### T8. Fail2ban Bypass (TA2)
- **Target**: Port 22
- **Attack**: Distributed brute force from multiple IPs, or exploit fail2ban vulnerability
- **Mitigations in place**: fail2ban with systemd backend, key-only auth
- **Residual risk**: LOW — even bypassing fail2ban, password auth is disabled
- **Dokploy impact**: No change

#### T9. UFW Docker Bypass (TA2)
- **Target**: A3 (container services)
- **Attack**: Access container-published ports that bypass UFW via Docker's iptables manipulation
- **Mitigations in place**: DOCKER-USER chain rules, private network ranges allowed, public blocked
- **Base residual risk**: LOW — rules are comprehensive for IPv4
- **Gap**: IPv6 rules not implemented (F8)
- **Dokploy impact**: Swarm overlay networking may introduce additional bypass vectors

#### T10. Privilege Escalation from docker user (TA3)
- **Target**: A1 (root access)
- **Attack**: Abuse passwordless sudo (F2) after gaining docker user shell
- **Mitigations in place**: auditd logs sudo usage
- **Residual risk**: N/A — passwordless sudo means docker user IS effectively root. This is by design but eliminates an escalation barrier.
- **Dokploy impact**: No change (already root-equivalent)

### Risk Matrix

```
              |  LOW impact  |  MED impact  |  HIGH impact  |  CRIT impact
--------------+--------------+--------------+---------------+--------------
HIGH likelihood|              | F5,F6        |               |
MED likelihood |              | F1,F2,F3     | D3,D4         | D1,D2
LOW likelihood | F7,F8,F9     | F4           | T3(dokploy)   | T7
VLOW likelihood|              |              | T5,T6,T9      | T2
```

---

## Recommendations

### Priority 1 — High Impact, Actionable Now

| # | Finding | Action | Profile |
|---|---------|--------|---------|
| R1 | D1 | Pin Dokploy version, verify checksum, do not pipe curl to sh as root | Dokploy |
| R2 | D2 | Document that Dokploy requires system Docker and negates rootless isolation. Consider a separate server. | Dokploy |
| R3 | D3 | Add firewall rule to restrict port 3000 to operator IP during initial setup | Dokploy |
| R4 | F1 | Change `PermitRootLogin` to `prohibit-password` or `no` | Both |
| R5 | F2 | Restrict sudo to necessary commands or add password requirement | Both |

### Priority 2 — Defense in Depth

| # | Finding | Action | Profile |
|---|---------|--------|---------|
| R6 | D4 | Configure TLS for Dokploy dashboard via reverse proxy | Dokploy |
| R7 | F4 | Verify lazydocker release checksums before install | Both |
| R8 | F5 | Use `ufw limit 22/tcp` instead of `ufw allow 22/tcp` | Both |
| R9 | F6 | Add `MaxAuthTries 3` and `LoginGraceTime 30` to SSH hardening | Both |
| R10 | F8 | Add IPv6 Docker rules to `/etc/ufw/after6.rules` | Both |

### Priority 3 — Best Practices

| # | Finding | Action | Profile |
|---|---------|--------|---------|
| R11 | F3 | Support separate SSH keys per user account | Both |
| R12 | F7 | Make ports 80/443 conditional based on intended use | Both |
| R13 | — | Add SSH 2FA (e.g., FIDO2/WebAuthn via `sk-ssh-ed25519`) | Both |
| R14 | — | Add ClamAV or rkhunter for malware scanning | Both |
| R15 | — | Configure log forwarding to external SIEM | Both |
| R16 | — | Add `AllowUsers` directive to restrict SSH to expected users | Both |
