# Architecture

## Overview

This project deploys a Vault-first, security-hardened Fedora workstation
using Ansible. It comprises **7 custom roles** and **16 vendored
linux-system-roles**, orchestrated through a five-phase master playbook
(`playbooks/site.yml`).

## Playbook Phase Ordering

The playbook executes in strict dependency order:

### Phase 0 -- SELinux Context Detection

Detects whether the SSH admin is mapped to `staff_u` (post-hardening) or
`unconfined_u` (first run). Sets `ansible_become_flags` accordingly so
`sudo` transitions to `sysadm_t` when required. Also fixes stale
SELinux context on Ansible's `remote_tmp` directory after reboot.

### Phase 1 -- Bootstrap

Installs the base system and the secrets backbone (Vault CE). Roles
execute in this order because each depends on the previous:

| Order | Role | Responsibilities |
| --- | --- | --- |
| 1 | `common` | Preflight checks (LUKS/TPM2), system update, package installation, USBGuard, SSH banner, polkit rules, graphical target |
| 2 | `dns` | Unbound (DNSSEC + DoT + blocklist), dnsconfd (NM integration, resolv.conf, split-DNS), browser DoH lockdown |
| 3 | `avahi` | Hardened mDNS/DNS-SD (user-service publishing blocked, no HINFO) |
| 4 | `vault` | Install, bootstrap TLS (ECDSA P-256), configure, init (age+TPM2), PKI engine, AppRole, Agent, production TLS, browser trust, secrets backup |
| 5 | `proxy` | Nginx reverse proxy (`https://vault.local` → `:8200`), cert rotation via systemd path unit |

### Phase 2 -- Harden

System roles pull secrets from the now-running Vault instance. Roles
are applied in dependency-aware tiers:

| Tier | Roles | Why This Order |
| --- | --- | --- |
| Tier 0 -- Foundation | `crypto_policies`, `timesync`, `tuned`, `kernel_settings`, `journald`, `bootloader`, `certificate`, `systemd` | Crypto baseline, time sync, kernel tuning first |
| Tier 1 -- Access | `sshd`, `auditd`, `tlog` | SSH and audit depend on crypto policies and time accuracy |
| Tier 2 -- Network + Auth | `firewall`, `selinux`, `auth` | Firewall rules and SELinux policy first, then authselect + PAM hardening (depends on SELinux for its own policy module) |
| Tier 3 -- Enforcement | `sudo`, `fapolicyd` | sudo confinement and application allowlisting are applied last; fapolicyd must run after all binaries are installed |

### Phase 3 -- Finalize

- **AIDE** initializes its database *last*, capturing the fully hardened
  filesystem as the integrity baseline
- **verification** runs read-only assertions to confirm all services are
  healthy

### Phase 4 -- Reboot (Conditional)

Reboots only if `/var/run/reboot-required` exists and `reboot_ok` is
set. Post-reboot verification confirms survival.

## Vault SSH Secrets Engine Architecture

The project uses two Vault SSH secrets engine mounts as complementary
credential layers (see
[ADR-0005](decisions/ADR-0005-vault-ssh-otp-ca.md)):

### OTP — Primary, Daily Use

Mounted at `ssh-otp/`, role `daily`. Vault generates a single-use
password; `vault-ssh-helper` on the target validates it against
Vault's API via PAM (`pam_exec.so`). The OTP is consumed on use and
never persisted. Rate-limited to 5 requests per 60 seconds.

### Ed25519 CA — Break-Glass

Mounted at `ssh-ca/`, role `breakglass`. Vault signs the user's SSH
public key with an internal Ed25519 CA. The target's `sshd` validates
the certificate locally using `TrustedUserCAKeys` — no Vault API call
at SSH-time. Used when Vault is degraded and OTP validation cannot
complete. Short-lived certificates: 24h default TTL, 72h max TTL.

Ed25519 was chosen for consistency with existing SSH host keys and
best performance. ECDSA P-521 was rejected as overkill for short-lived
certs. OpenSSH does not support CA certificate chaining (`PROTOCOL.certkeys`:
"Chained certificates are NOT supported"), which affects the CA key
rotation procedure documented in [OPERATIONS.md](OPERATIONS.md).

## SSH Credential Gateway

Vault's API is loopback-only (`127.0.0.1:8200`) and remains so
permanently. A narrowly-scoped Nginx gateway on port 8443 exposes
exactly two Vault API paths to the bastion host, enabling the OTP and
CA credential workflows (see
[ADR-0006](decisions/ADR-0006-ssh-credential-gateway.md)):

| Path | Purpose |
| --- | --- |
| `/v1/ssh-otp/creds/` | Request a one-time password |
| `/v1/ssh-ca/sign/` | Request a signed SSH certificate |

All other paths return HTTP 403. Defence in depth:

1. **Firewall** — only `bastion_ip` can reach port 8443
2. **Nginx location blocks** — only two paths proxied
3. **Vault policy** — `ssh-otp-user` grants only `create`/`update`
4. **Rate limit** — 5 requests / 60 seconds on `ssh-otp/creds/daily`

The existing UI/admin proxy (`127.0.0.1:443`) is unchanged and
remains loopback-only.

## LAN DNS Feature Flag

The dns role supports optional LAN-facing DNS caching, disabled by
default. When enabled, the workstation serves as a caching DNS
resolver for devices on the local network.

| Variable | Default | Purpose |
| --- | --- | --- |
| `dns_lan_enabled` | `false` | Master toggle for LAN DNS |
| `dns_lan_subnet` | `192.168.122.0/24` | Allowed client subnet |
| `dns_lan_interface` | `""` | LAN-facing interface (empty = all) |

When `dns_lan_enabled: true`:

- dnsconfd listens on `0.0.0.0` instead of `127.0.0.1`
- Unbound `access-control` adds the LAN subnet
- Firewall opens DNS (53/udp, 53/tcp) for the LAN subnet only

A security guard rejects dangerous configurations:

- `dns_lan_subnet` must be defined and non-empty
- `dns_lan_subnet` must not be `0.0.0.0/0` (open resolver)
- Prefix length must be `/8` or narrower

## Custom Roles

### common

Preflight validation (LUKS encryption, TPM2 availability), system
updates, package installation (including third-party repos for Chrome
and VS Code), USBGuard device policy, SSH login banner, polkit rules
for GUI systemd management, and graphical target configuration.

### dns

Manages the full DNS stack:

- **Unbound** -- local caching resolver with DNSSEC validation, DoT
  upstream, performance tuning, privacy hardening, and blocklist
  (Steven Black + Hagezi Pro + URLhaus, ~76K entries, daily update
  via systemd timer)
- **dnsconfd** -- RHEL-standard NetworkManager-to-Unbound integration
  layer managing `resolv.conf`, DoT upstream servers, and
  `tls-cert-bundle`
- Browser policies to prevent DoH bypass (Firefox canary domain
  sinkholed, Chrome enterprise policy)

### avahi

Hardened mDNS/DNS-SD for local service discovery (GNOME
printer/file sharing). User-service publishing blocked, OS/CPU
fingerprinting disabled, core dumps prevented, wide-area DNS-SD off.

### vault

Complete HashiCorp Vault CE lifecycle: binary installation, bootstrap
TLS (self-signed ECDSA P-256), server configuration, operator init
with age+TPM2 key encryption, internal PKI engine with intermediate
CA, AppRole authentication, Vault Agent for automated cert rotation,
production TLS certificate swap, browser trust store configuration,
and secrets backup to KV.

Custom SELinux policy (`vault_t`) with `gen_tunable` booleans for
optional network access (see
[ADR-0002](decisions/ADR-0002-vault-selinux-policy.md)).

### proxy

Nginx reverse proxy serving `https://vault.local` (port 443) proxied
to Vault on port 8200. Uses a separate PKI-issued leaf certificate
(vault.local SAN only). Cert rotation handled by a systemd path unit
watching for file changes (see
[ADR-0003](decisions/ADR-0003-cert-rotation-path-units.md)).

### auth

Authselect profile management and PAM hardening, placed in Phase 2
Tier 2 (after SELinux, before sudo). Replaces the previous Phase 2
post\_task nsswitch workaround with integrated handling. Responsibilities:

- **Authselect** — selects the `sssd` profile with features:
  `with-tlog`, `with-faillock`, `with-pamaccess`, `with-pwhistory`,
  `without-nullok`
- **PAM faillock** — account lockout after failed attempts
  (CIS RHEL 9 v3.0.0 controls 5.3.2.2 module enablement,
  5.3.3.1.x deny/unlock values)
- **PAM pwquality** — password complexity requirements
  (CIS 5.3.3.2.2 minimum length = 14, minclass = 4)
- **PAM pwhistory** — password reuse prevention
  (CIS 5.3.3.3.1 remember = 24)
- **vault-ssh-helper** — PAM integration for Vault OTP validation
  via `pam_exec.so`, configured to reach Vault at
  `https://127.0.0.1:8200` using the system CA trust bundle
- **nsswitch.conf** — hosts line override (post-authselect) to
  preserve mDNS resolution:
  `files mdns_minimal [NOTFOUND=return] myhostname dns`
- **SELinux Option A** — `sshd-vault-ssh-helper.te` allows `sshd_t`
  to connect to `vault_cluster_port_t` (port 8200) for OTP validation.
  Option B (dedicated `vault_ssh_helper_t` domain transition) is the
  long-term plan, tracked in [KNOWN_ISSUES.md](KNOWN_ISSUES.md) backlog.

Includes a forward-compatibility placeholder for FIDO2/U2F
(`auth_pam_u2f_enabled: false`).

### verification

Post-deployment read-only assertions: service health, TLS certificate
validity, Vault seal status, firewall rules, SELinux enforcing mode,
DNS resolution, and more.

## Configuration Ownership

### dnsconfd vs. dns role

A clear ownership boundary exists between dnsconfd and the Ansible dns
role (see [ADR-0001](decisions/ADR-0001-unbound-dnsconfd-ownership.md)):

| Directive | Owner | Mechanism |
| --- | --- | --- |
| DoT upstream servers | dnsconfd | `static_servers` in `dnsconfd.conf` |
| `resolv.conf` | dnsconfd | Managed symlink |
| `tls-cert-bundle` | dnsconfd | `certification_authority` pushes to Unbound runtime |
| Security/performance/privacy | dns role | `unbound.conf.j2` template |
| Site-local overrides | dns role | `/etc/unbound/conf.d/*.conf` drop-ins |
| RPZ zones | dns role | Direct Unbound `conf.d` (not dnsconfd); see [ADR-0004](decisions/ADR-0004-rpz-via-unbound-native-not-dnsconfd.md) |

### Vault cert rotation

Cert rotation uses systemd path units (`PathModified`) instead of
cron or timer+inotifywait (see
[ADR-0003](decisions/ADR-0003-cert-rotation-path-units.md)):

- `vault-cert-reload.path` watches `/etc/vault.d/certs/server-chain.crt`
- `nginx-cert-reload.path` watches the proxy TLS cert

When Vault Agent writes a new certificate, the path unit triggers the
corresponding reload service immediately.

## Variable Management

- **Non-sensitive variables**: single source of truth in
  `inventory/group_vars/all/main.yml`
- **Sensitive variables**: `inventory/group_vars/all/vault.yml`
  (encrypted with `ansible-vault`)
- Galaxy roles are gitignored; install via `make venv` or `make galaxy`
