# Threat Model: RidgeGuard

This document provides a security review and threat model for the ridgeguard toolset, covering two deployment scenarios:

1. **Standalone** — Server hardened with ridgeguard only
2. **With Dokploy** — Server hardened with ridgeguard, then Dokploy installed as a self-hosted PaaS

---

## Table of Contents

- [1. System Overview](#1-system-overview)
- [2. Security Controls Summary](#2-security-controls-summary)
- [3. Threat Actors](#3-threat-actors)
- [4. Attack Surface Analysis](#4-attack-surface-analysis)
- [5. Module-by-Module Security Review](#5-module-by-module-security-review)
- [6. Standalone Threat Model](#6-standalone-threat-model)
- [7. Dokploy Threat Model](#7-dokploy-threat-model)
- [8. Risk Matrix](#8-risk-matrix)
- [9. Recommendations](#9-recommendations)

---

## 1. System Overview

### What the Toolset Does

The toolset applies 15 sequential modules (13 base hardening + optional Dokploy + verification) to a fresh Ubuntu 24.04 LTS+ server:

| Module | Control |
|--------|---------|
| 01 | System package updates |
| 02 | SSH public key installation |
| 03 | SSH daemon hardening (pubkey-only, no passwords) |
| 04 | UFW firewall (deny-by-default, allow 22/80/443) |
| 05 | UFW iptables rules for Docker container isolation |
| 06 | Fail2ban SSH jail (1h ban, 5 retries in 10m) |
| 07 | Kernel sysctl hardening (SYN cookies, anti-spoofing, etc.) |
| 08 | Unattended security upgrades |
| 09 | Logwatch + auditd monitoring |
| 10 | SSH service restart |
| 11 | Docker user creation with sudo |
| 12 | Docker Engine in rootless mode |
| 13 | Lazydocker terminal UI |
| 14 | Dokploy self-hosted PaaS (optional) |
| 15 | Verification report |

### Trust Boundaries

```
Internet
   │
   ├── [TCP 22]  ──▶  SSH Daemon  ──▶  Shell (root / docker user)
   ├── [TCP 80]  ──▶  (no listener unless app deployed)
   ├── [TCP 443] ──▶  (no listener unless app deployed)
   │
   └── All other ports ──▶  UFW DROP
                                │
                                ▼
                    Docker rootless namespace
                    (containers run as unprivileged)
```

---

## 2. Security Controls Summary

### Defense-in-Depth Layers

| Layer | Control | Status |
|-------|---------|--------|
| Authentication | SSH pubkey-only, no passwords | Applied |
| Brute-force protection | Fail2ban (5 retries → 1h ban) | Applied |
| Network filtering | UFW deny-by-default | Applied |
| Container isolation | Docker rootless mode + UFW DOCKER-USER rules | Applied |
| Kernel hardening | sysctl (SYN cookies, rp_filter, no redirects) | Applied |
| Patch management | Unattended security upgrades | Applied |
| Audit trail | auditd watches on /etc/passwd, shadow, sudoers, sshd_config | Applied |
| Log monitoring | Logwatch daily summaries | Applied |
| Privilege separation | Dedicated docker user, rootless containers | Partial (see findings) |

### What Is NOT Covered

- Application-layer security (WAF, input validation)
- TLS certificate management
- Intrusion detection systems (OSSEC, Wazuh)
- File integrity monitoring (AIDE, Tripwire)
- Centralized logging / SIEM
- AppArmor / SELinux profiles
- Container image scanning
- Backup and disaster recovery
- DNS security (DNSSEC, DoH)
- Physical security

---

## 3. Threat Actors

| Actor | Capability | Motivation | Relevant Scenario |
|-------|-----------|------------|-------------------|
| **Opportunistic scanner** | Automated tools, Shodan, masscan | Botnet recruitment, cryptomining | Both |
| **Script kiddie** | Public exploits, credential stuffing | Defacement, spam relay | Both |
| **Targeted attacker** | Custom exploits, persistence | Data theft, ransomware | Both |
| **Insider / compromised CI** | Valid SSH key, deploy credentials | Lateral movement, supply chain | With Dokploy |
| **Malicious PR author** | Pull request with code execution | Secret exfiltration via preview deploys | With Dokploy |

---

## 4. Attack Surface Analysis

### Standalone (No Dokploy)

| Surface | Exposure | Protection |
|---------|----------|------------|
| SSH (port 22) | Internet | Pubkey-only + fail2ban |
| HTTP/HTTPS (80/443) | Internet (no listener by default) | UFW allows, nothing listening |
| Docker containers | Isolated by UFW DOCKER-USER rules | Rootless mode + iptables |
| Kernel network stack | Internet | sysctl hardening |
| Local privilege escalation | Docker user with NOPASSWD sudo | **Weakness — see findings** |

**Listening services post-setup:** SSH only (ports 80/443 open in UFW but no service bound).

### With Dokploy

| Surface | Exposure | Protection |
|---------|----------|------------|
| SSH (port 22) | Internet | Pubkey-only + fail2ban |
| HTTP (port 80) | Internet | Traefik reverse proxy |
| HTTPS (port 443) | Internet | Traefik with TLS |
| Dokploy dashboard (port 3000) | Internet | Username/password + optional 2FA |
| Docker Swarm (2377, 7946, 4789) | Network | Should be firewalled to cluster only |
| PostgreSQL (internal) | Docker network | No host binding (internal only) |
| Redis (internal) | Docker network | No host binding (internal only) |
| Docker API socket | Local | Mounted into Dokploy container |
| Traefik admin | Docker network | Not exposed by default |
| Preview deployments | Internet | **Weakness — unauthenticated code execution** |
| Registration endpoint | Internet | **Weakness — may allow arbitrary signup** |

**Critical difference:** Dokploy requires Docker in rootful mode, which **conflicts with the rootless Docker setup** from module 12. Docker in rootful mode bypasses UFW entirely by writing its own iptables rules.

---

## 5. Module-by-Module Security Review

### Module 03 — SSH Hardening

**Finding: CRITICAL — PermitRootLogin is set to "yes"**

```bash
set_sshd_option "PermitRootLogin" "yes"
```

Direct root SSH login is enabled. While password authentication is disabled (pubkey-only), this still:
- Exposes the root account to key-based attacks
- Violates CIS Benchmark 5.2.10 (should be "no" or "prohibit-password")
- Provides no privilege separation — a compromised key gives immediate root

**Recommendation:** Change to `prohibit-password` (allows pubkey but blocks password) or `no` (forces login as unprivileged user first, then `sudo`).

### Module 04 — UFW Setup

**Finding: LOW — No rate limiting at the firewall level**

UFW allows unlimited connection attempts to ports 80/443. Fail2ban covers SSH only. Application-layer DoS is unmitigated at the network level.

### Module 05 — UFW Docker Rules

**Finding: IMPORTANT — Rules only effective with rootless Docker**

The DOCKER-USER iptables chain rules work correctly with rootless Docker. However, if Docker is later reinstalled in rootful mode (e.g., for Dokploy), Docker rewrites iptables rules on every restart, potentially bypassing these protections.

### Module 06 — Fail2ban

**Finding: LOW — maxretry=5 is permissive**

Five failed SSH attempts before a ban allows a moderate brute-force window. CIS recommends maxretry=3. The 1-hour ban duration is reasonable.

**Missing:** No jails for HTTP/HTTPS brute-force (relevant when web services are deployed).

### Module 07 — Sysctl Hardening

**Finding: MEDIUM — Missing additional kernel hardening**

Applied controls are solid. Missing:
- `kernel.dmesg_restrict = 1` (prevent unprivileged dmesg access)
- `kernel.kptr_restrict = 2` (hide kernel pointers)
- `fs.protected_hardlinks = 1` / `fs.protected_symlinks = 1`
- `kernel.yama.ptrace_scope = 1` (restrict ptrace)
- IPv6 disable if unused (`net.ipv6.conf.all.disable_ipv6 = 1`)

### Module 09 — Logwatch + Auditd

**Finding: LOW — Audit rules are minimal**

Current watches cover identity files, SSH config, and sudo. Missing:
- Failed login tracking (`-w /var/log/faillog`)
- Cron modification (`-w /etc/crontab`, `-w /var/spool/cron`)
- Kernel module loading (`-a always,exit -F arch=b64 -S init_module`)
- Network configuration changes
- Time change events

### Module 11 — Docker User

**Finding: HIGH — NOPASSWD:ALL grants unrestricted root**

```bash
echo "$DOCKER_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
```

The docker user can run any command as root without a password. If an attacker gains access to the docker user (via SSH key compromise, container escape, or application vulnerability), they have immediate, unrestricted root access with no additional barrier.

**Impact:** Eliminates the value of privilege separation between the docker user and root.

**Recommendation:** Restrict to necessary commands:
```bash
docker ALL=(ALL) NOPASSWD:/usr/bin/docker, /usr/bin/docker-compose, /bin/systemctl restart docker*
```

### Module 12 — Docker Rootless

**Finding: GOOD — Strong isolation, but incompatible with Dokploy**

Rootless Docker runs the daemon and containers under an unprivileged user with UID remapping (subuid 100000-165535). This is excellent isolation. However, Dokploy requires rootful Docker with Swarm mode, creating a fundamental conflict.

---

## 6. Standalone Threat Model

### STRIDE Analysis

| Threat | Category | Scenario | Likelihood | Impact | Mitigation |
|--------|----------|----------|------------|--------|------------|
| T1 | Spoofing | Attacker uses stolen SSH key to log in as root | Medium | Critical | PermitRootLogin=yes allows direct root access. Change to "no" and force sudo |
| T2 | Spoofing | SSH brute-force against key auth | Very Low | Critical | Pubkey-only makes password brute-force impossible. Key brute-force infeasible |
| T3 | Tampering | Attacker modifies sshd_config to re-enable passwords | Low | Critical | Auditd watches sshd_config. Alert on changes |
| T4 | Tampering | Container escape to host filesystem | Low | High | Rootless Docker + UID remapping limits blast radius |
| T5 | Repudiation | Attacker clears logs after compromise | Medium | Medium | Auditd provides secondary log. No remote syslog makes log destruction possible |
| T6 | Info Disclosure | Exposed Docker container ports leak data | Low | Medium | UFW DOCKER-USER rules block external access to container ports |
| T7 | Denial of Service | SYN flood against SSH/HTTP | Medium | Medium | SYN cookies enabled. No rate limiting on 80/443 |
| T8 | Elevation of Privilege | Docker user runs `sudo su` | High (if docker user compromised) | Critical | NOPASSWD:ALL grants immediate root. No barrier |
| T9 | Elevation of Privilege | Kernel exploit from container | Very Low | Critical | Rootless mode + sysctl hardening reduce surface |

### Key Standalone Risks (Ranked)

1. **PermitRootLogin=yes + stolen SSH key = immediate root compromise** (Critical)
2. **NOPASSWD:ALL for docker user = no privilege boundary** (High)
3. **No remote logging = logs can be destroyed by attacker** (Medium)
4. **No file integrity monitoring = silent config tampering** (Medium)
5. **No IDS = no real-time intrusion alerting** (Low)

---

## 7. Dokploy Threat Model

### Architecture Change

Installing Dokploy fundamentally changes the server's security posture:

```
Internet
   │
   ├── [TCP 22]   ──▶  SSH Daemon
   ├── [TCP 80]   ──▶  Traefik (HTTP → HTTPS redirect)
   ├── [TCP 443]  ──▶  Traefik ──▶ Deployed apps / Dokploy UI
   ├── [TCP 3000] ──▶  Dokploy Dashboard (if not proxied via Traefik)
   │
   ├── [TCP 2377] ──▶  Docker Swarm management  ← MUST be firewalled
   ├── [TCP 7946] ──▶  Swarm node communication ← MUST be firewalled
   ├── [UDP 4789] ──▶  Overlay network          ← MUST be firewalled
   │
   └── Docker API socket mounted into Dokploy container
                              │
                              ▼
                   Root-level Docker daemon
                   (containers run as root by default)
```

### Conflicts with ridgeguard Hardening

| ridgeguard Control | Dokploy Conflict | Severity |
|----------------------|------------------|----------|
| Docker rootless mode (module 12) | Dokploy requires rootful Docker + Swarm | **Breaking** — must disable rootless and install rootful Docker |
| UFW DOCKER-USER rules (module 05) | Rootful Docker rewrites iptables, bypassing UFW | **Critical** — firewall rules become ineffective for Docker-exposed ports |
| Minimal listening services | Dokploy adds Traefik, PostgreSQL, Redis, dashboard | **High** — significantly expanded attack surface |
| Privilege separation (docker user) | Dokploy runs as root, mounts Docker socket | **High** — container compromise = root compromise |

### STRIDE Analysis (Dokploy-Specific)

| Threat | Category | Scenario | Likelihood | Impact | Mitigation |
|--------|----------|----------|------------|--------|------------|
| D1 | Spoofing | Attacker accesses Dokploy dashboard with default/weak credentials | Medium | Critical | Enable 2FA, use strong passwords, proxy behind Traefik with IP allowlist |
| D2 | Spoofing | Open registration endpoint allows arbitrary account creation | High | Critical | Disable public registration immediately after initial setup |
| D3 | Tampering | Malicious PR triggers preview deployment, exfiltrates env secrets | High (if preview deploys enabled on public repos) | Critical | Disable preview deployments for public repositories |
| D4 | Tampering | Attacker with dashboard access deploys malicious container | Medium | Critical | Container has Docker socket access → root on host |
| D5 | Tampering | Docker API socket exploitation from compromised container | Medium | Critical | Any container with socket mount can control all containers and host |
| D6 | Info Disclosure | Dokploy PostgreSQL/Redis exposed on Docker network | Low | High | Internal-only by default, but any container on dokploy-network can reach them |
| D7 | Info Disclosure | Environment variables/secrets visible in Dokploy UI | Medium | High | Restrict dashboard access. Rotate secrets regularly |
| D8 | Denial of Service | Traefik targeted with HTTP flood | Medium | High | Add rate limiting in Traefik config. Consider external CDN/WAF |
| D9 | Elevation of Privilege | Authenticated low-privilege Dokploy user executes OS commands (known CVE) | Medium | Critical | Keep Dokploy updated. Restrict user roles |
| D10 | Elevation of Privilege | Docker Swarm ports exposed to internet allow cluster join | High (if ports not firewalled) | Critical | Firewall 2377/7946/4789 to cluster IPs only |

### Key Dokploy Risks (Ranked)

1. **UFW bypass — rootful Docker ignores firewall rules** (Critical)
   - Docker writes its own iptables FORWARD rules that take precedence over UFW
   - Any port published by a container is accessible from the internet regardless of UFW
   - The UFW DOCKER-USER rules from module 05 become ineffective

2. **Docker socket mount = root equivalent** (Critical)
   - Dokploy container has the Docker socket mounted
   - Compromise of Dokploy = ability to create privileged containers = root on host

3. **Dashboard exposed to internet without 2FA enforcement** (Critical)
   - Default installation exposes port 3000 to the internet
   - No mandatory 2FA; password-only auth by default

4. **Preview deployment RCE** (Critical, if enabled)
   - Known vulnerability: malicious PRs on public repos can execute code and steal secrets
   - Runs without authentication

5. **Docker Swarm ports exposed** (High)
   - Ports 2377, 7946, 4789 allow cluster manipulation if reachable
   - UFW rules may not block these due to Docker's iptables manipulation

6. **Loss of rootless Docker isolation** (High)
   - Containers run as root inside the namespace
   - Container escape = host root access
   - No UID remapping by default in Swarm mode

---

## 8. Risk Matrix

### Standalone Server

| ID | Risk | Severity | Likelihood | Rating |
|----|------|----------|------------|--------|
| S1 | Root SSH login with stolen key | Critical | Medium | **High** |
| S2 | Docker user NOPASSWD privilege escalation | Critical | Medium | **High** |
| S3 | Log destruction after compromise | Medium | Medium | **Medium** |
| S4 | No file integrity monitoring | Medium | Medium | **Medium** |
| S5 | Fail2ban bypass via distributed attack | Medium | Low | **Low** |
| S6 | Container escape (rootless) | Critical | Very Low | **Low** |
| S7 | SYN/HTTP flood DoS | Medium | Medium | **Medium** |
| S8 | Kernel exploit via container | Critical | Very Low | **Low** |

### With Dokploy

| ID | Risk | Severity | Likelihood | Rating |
|----|------|----------|------------|--------|
| K1 | UFW bypassed by rootful Docker | Critical | Certain | **Critical** |
| K2 | Docker socket = root compromise | Critical | Medium | **Critical** |
| K3 | Dashboard brute-force (no 2FA) | Critical | Medium | **High** |
| K4 | Preview deploy RCE | Critical | High | **Critical** |
| K5 | Open registration endpoint | Critical | High | **Critical** |
| K6 | Swarm ports internet-exposed | Critical | High | **High** |
| K7 | Authenticated user RCE (known CVE) | Critical | Medium | **High** |
| K8 | Env/secret leakage via dashboard | High | Medium | **High** |
| K9 | Inter-container lateral movement | High | Low | **Medium** |
| K10 | Traefik misconfiguration exposing internal services | High | Medium | **High** |

---

## 9. Recommendations

### Standalone Server — Required Fixes

| Priority | Action | Addresses |
|----------|--------|-----------|
| **P0** | Change `PermitRootLogin` from `yes` to `prohibit-password` or `no` | S1 |
| **P0** | Replace `NOPASSWD:ALL` with command-specific sudo whitelist | S2 |
| **P1** | Add `MaxAuthTries 3`, `ClientAliveInterval 300`, `ClientAliveCountMax 2` to sshd_config | S1, S5 |
| **P1** | Add kernel hardening: `dmesg_restrict=1`, `kptr_restrict=2`, `yama.ptrace_scope=1` | S8 |
| **P1** | Configure remote syslog or log forwarding | S3 |
| **P2** | Add fail2ban jails for HTTP auth failures (when web services deployed) | S7 |
| **P2** | Install AIDE or similar file integrity monitoring | S4 |
| **P2** | Reduce fail2ban `maxretry` from 5 to 3 | S5 |
| **P3** | Add auditd rules for cron, kernel modules, network config changes | S3 |
| **P3** | Consider disabling IPv6 if unused | S7 |

### With Dokploy — Required Fixes

| Priority | Action | Addresses |
|----------|--------|-----------|
| **P0** | Accept that UFW cannot protect Docker-published ports; use Traefik and Docker network policies for access control instead | K1 |
| **P0** | Firewall Swarm ports (2377, 7946, 4789) to cluster node IPs only using iptables rules outside UFW | K6 |
| **P0** | Disable preview deployments for public repositories | K4 |
| **P0** | Disable or protect the `/register` endpoint after initial admin account creation | K5 |
| **P0** | Enable 2FA on all Dokploy admin accounts | K3 |
| **P0** | Keep Dokploy updated to latest version (patch known RCE) | K7 |
| **P1** | Proxy Dokploy dashboard (port 3000) behind Traefik with IP allowlist or VPN | K3, K5 |
| **P1** | Do NOT skip module 12 (rootless Docker) — instead, accept that Dokploy requires a separate rootful Docker install and document the tradeoff | K2 |
| **P1** | Add Traefik rate limiting middleware for all public-facing services | K10 |
| **P1** | Restrict Docker socket access: consider socket proxy (e.g., Tecnativa/docker-socket-proxy) with read-only where possible | K2 |
| **P2** | Use Docker secrets instead of environment variables for sensitive values | K8 |
| **P2** | Segment container networks — don't put all services on the same overlay network | K9 |
| **P2** | Add Traefik IP allowlist for admin routes | K10 |
| **P3** | Consider running Dokploy on a separate management server from production workloads | K2, K9 |

### Deployment Decision Matrix

| Factor | Standalone | With Dokploy |
|--------|-----------|--------------|
| Attack surface | Minimal (SSH only) | Large (SSH + Traefik + Dashboard + Swarm + Docker API) |
| Docker isolation | Rootless (strong) | Rootful (weak) |
| Firewall effectiveness | UFW works as expected | UFW bypassed by Docker; must use alternative controls |
| Management complexity | Manual (SSH + scripts) | Web UI (convenient but high-value target) |
| Suitable for | Single-purpose servers, static workloads | Multi-app deployments needing frequent changes |
| Required skill level | Moderate (Linux admin) | Higher (must understand Docker networking + Traefik + Swarm security) |

---

## Appendix: Test Coverage Assessment

The existing test suite validates many security controls:

| Test | What It Verifies |
|------|-----------------|
| Pentest 01 (SSH attacks) | Password rejection, key auth, wrong key rejection, fail2ban ban trigger |
| Pentest 02 (Network) | Only 22/80/443 open, blocked ports filtered, UFW policies correct |
| Pentest 03 (Privilege escalation) | File permissions, no empty passwords, SUID audit, sudo group membership |
| Pentest 04 (Config audit) | Sysctl values, sshd settings, service status, audit rules |

**Not tested:**
- Docker container escape scenarios
- UFW bypass via rootful Docker
- Application-layer attacks (XSS, SQLi) — out of scope
- Lateral movement between containers
- Log tampering detection
- Dokploy-specific attack vectors
