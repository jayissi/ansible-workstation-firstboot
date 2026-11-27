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

| Order | Role     | Responsibilities                                                                                                                                                                      |
|-------|----------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1     | `common` | Preflight checks (LUKS/TPM2), system update, package installation, USBGuard, SSH banner, polkit rules, graphical target                                                               |
| 2     | `dns`    | Unbound (DNSSEC + DoT + blocklist), dnsconfd (NM integration, resolv.conf, split-DNS), browser DoH lockdown                                                                           |
| 3     | `avahi`  | Hardened mDNS/DNS-SD (user-service publishing blocked, no HINFO)                                                                                                                      |
| 4     | `vault`  | Install, bootstrap TLS (ECDSA P-384), configure, init (age+TPM2), PKI engine (3 roles), AppRole, Agent, production TLS, cert auth + OIDC, VaultPass KV, browser trust, secrets backup |
| 5     | `proxy`  | Nginx reverse proxy (`https://vault.internal` → `:8202` via backend mTLS), cert rotation via systemd path unit                                                                        |

### Phase 2 -- Harden

System roles pull secrets from the now-running Vault instance. Roles
are applied in dependency-aware tiers:

| Tier                     | Roles                                                                                                         | Why This Order                                                                                                          |
|--------------------------|---------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------|
| Tier 0 -- Foundation     | `crypto_policies`, `timesync`, `tuned`, `kernel_settings`, `journald`, `bootloader`, `certificate`, `systemd` | Crypto baseline, time sync, kernel tuning first                                                                         |
| Tier 1 -- Access         | `sshd`, `auditd`, `tlog`                                                                                      | SSH and audit depend on crypto policies and time accuracy                                                               |
| Tier 2 -- Network + Auth | `firewall`, `selinux`, `auth`                                                                                 | Firewall rules and SELinux policy first, then authselect + PAM hardening (depends on SELinux for its own policy module) |
| Tier 3 -- Enforcement    | `sudo`, `fapolicyd`                                                                                           | sudo confinement and application allowlisting are applied last; fapolicyd must run after all binaries are installed     |

### Phase 3 -- Finalize

`playbooks/site.yml` `pre_tasks` for Phase 3 implement an AIDE
baseline-existence gate:

1. `stat` checks for `/var/lib/aide/aide.db.gz`
2. `aide_init` is set dynamically: `true` only when no baseline exists
   (first-ever bootstrap)

**Security rationale:** running `aide --init` unconditionally on every
deploy would silently overwrite the integrity baseline with whatever
the filesystem looks like at that moment — including any unauthorized
tampering between deploys. This defeats AIDE's entire purpose.
Periodic drift detection runs independently via the `aide_cron_check`
cron job (04:05 daily, `aide --check`), unaffected by this gate. See
[OPERATIONS.md](OPERATIONS.md) for the deliberate re-baseline
procedure.

- **AIDE** initializes its database *last*, capturing the fully hardened
  filesystem as the integrity baseline (first deploy only)
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

| Path                 | Purpose                          |
|----------------------|----------------------------------|
| `/v1/ssh-otp/creds/` | Request a one-time password      |
| `/v1/ssh-ca/sign/`   | Request a signed SSH certificate |

All other paths return HTTP 403. Defence in depth:

1. **Firewall** — only `bastion_ip` can reach port 8443 (rule in the
   bound `FedoraWorkstation` DROP zone)
2. **Mutual TLS** — the bastion must present a client certificate from
   the Vault Intermediate CA with `OU=Bastion Gateway` (PKI role
   `bastion-gateway-client`); CRL-checked. Other certificates from the
   same CA get 403 (KNOWN_ISSUES P26)
3. **Host allow-list** — any `Host` other than the VM address or
   `vault-ssh-gateway.internal` is closed with 444 (P28, adapted: the
   bastion connects by IP without SNI, so the gateway stays the 8443
   `default_server` and checks `Host` itself)
4. **Nginx location blocks** — only two paths proxied, `POST`/`PUT`
   only (P27); client-supplied `X-Client-Cert` stripped and
   `X-Forwarded-For` overwritten so Vault's audit log shows the real
   address
5. **Vault policy** — `ssh-otp-user` grants only `create`/`update`
6. **Rate limit** — 5 requests / 60 seconds on `ssh-otp/creds/daily`

The existing UI/admin proxy (`127.0.0.1:443`) is unchanged and
remains loopback-only.

## LAN DNS Feature Flag

The dns role supports optional LAN-facing DNS caching, disabled by
default. When enabled, the workstation serves as a caching DNS
resolver for devices on the local network.

| Variable            | Default            | Purpose                            |
|---------------------|--------------------|------------------------------------|
| `dns_lan_enabled`   | `false`            | Master toggle for LAN DNS          |
| `dns_lan_subnet`    | `192.168.122.0/24` | Allowed client subnet              |
| `dns_lan_interface` | `""`               | LAN-facing interface (empty = all) |

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

Preflight validation (LUKS encryption, TPM2 availability, Secure Boot
detection), system updates, package installation (including third-party
repos for Chrome and VS Code), USBGuard device policy, SSH login
banner, polkit rules for GUI systemd management, hardware tuning, and
graphical target configuration.

**Session controls** (`tasks/session.yml`): idle shell timeout
`TMOUT` from `common_shell_timeout` (default 3600 s; CIS 5.6.4),
`/etc/cron.allow` + `/etc/at.allow` limited to root and the admin
(CIS 5.1.8-9), and on GNOME hosts a locked dconf screen lock
(`common_screen_idle_delay`, default 900 s) plus the GDM login banner
(CIS 1.8.x).

**Preflight Secure Boot check** — `roles/common/tasks/preflight.yml`
detects Secure Boot state via `mokutil --sb-state` (with EFI variable
fallback). The check is **advisory WARN only** (never fails the play)
because VMs may lack Secure Boot support. When disabled, the warning
notes that TPM2 PCR-bound unseal will be skipped since PCR values are
meaningless without a trusted boot chain. A matching advisory check
runs in `roles/verification/tasks/hardware.yml` post-deploy.

**Hardware tuning** — `roles/common/tasks/hardware_tuning.yml` handles
three categories of hardware-aware service management:

- **mcelog removal** — unconditionally removed (`dnf remove`) on all
  hosts. Deprecated since 2020, unmaintained, no CVE patches, Fedora
  ships it masked since F36.
- **rasdaemon** — installed and enabled on physical hosts only
  (`ansible_virtualization_role != 'guest'`). Monitors MCE, PCIe AER,
  DIMM CE/UE, and disk I/O errors via kernel `ras:*` tracepoints.
- **ALSA service masking** — `alsa-state.service` and
  `alsa-restore.service` are stopped and masked when no audio hardware
  is detected. Detection uses `/proc/asound/cards` hardware presence
  (not a VM-vs-physical check), covering both VMs without virtual
  audio and physical machines without sound hardware.

### dns

Manages the full DNS stack:

- **Unbound** -- local caching resolver with DNSSEC validation, DoT
  upstream, performance tuning and privacy hardening. Blocking uses two
  independent sources: the oisd "small" RPZ zone (ADR-0004) and a core
  `local-zone` blocklist from HaGeZi Threat Intelligence Feeds (mini),
  refreshed daily by a systemd timer, so blocking survives an RPZ
  failure (KNOWN_ISSUES P22). Local names use `.internal` (ADR-0008)
  with an explicit TTL (`dns_local_data_ttl`)
- **dnsconfd** -- RHEL-standard NetworkManager-to-Unbound integration
  layer managing `resolv.conf`, DoT upstream servers, and
  `tls-cert-bundle`. Config is rendered to `/etc/dnsconfd.conf` (the
  path the package reads) from `dns_dot_upstreams` -- Quad9 and
  Cloudflare malware-filtering endpoints only (P15). Outbound tcp/853
  is pinned to exactly those addresses by the firewalld `dot-egress`
  policy (P16)
- **systemd sandboxing** -- `unbound` and `dnsconfd` run with drop-ins
  (`ProtectHome`, kernel/cgroup protection,
  `LimitCORE=0`; `ProtectSystem=full` for unbound) (P23)
- Browser policies to prevent DoH bypass (Firefox canary domain
  sinkholed, Chrome enterprise policy)

### avahi

Hardened mDNS/DNS-SD for local service discovery (GNOME
printer/file sharing). User-service publishing blocked, OS/CPU
fingerprinting disabled, core dumps prevented, wide-area DNS-SD off.

### vault

Complete HashiCorp Vault CE lifecycle: binary installation, bootstrap
TLS (self-signed ECDSA P-384), server configuration, operator init
with age+TPM2 key encryption, internal PKI engine with Root and
Intermediate CA (ECDSA P-384, CNSA 2.0 compliant), 5 distinct PKI
roles, AppRole authentication (bounded, loopback-bound `secret_id`,
auto-rotated), Vault Agent for automated cert rotation,
production TLS certificate swap, TLS client certificate authentication
with OIDC provider integration (`cert_auth.yml`), KV secret seeding
with per-user folders (`vaultpass.yml`: shared `default/` read-only,
`<user>/` read/write, cert roles mapped by CN), browser trust store
configuration (Root CA + VaultPass extension), and secrets backup to
KV.

Custom SELinux policy (`vault_t`) with `gen_tunable` booleans for
optional network access (see
[ADR-0002](decisions/ADR-0002-vault-selinux-policy.md)). As of v1.4.0,
`vault.te` also grants `devlog_t:unix_dgram_socket sendto` to enable
the syslog audit backend (Vault needs to send log entries to
`/dev/log`); v1.5.0 adds a `dontaudit` for the Agent split scripts'
awk `isatty()` ioctl probe. The vault role additionally deploys `logrotate-vault.te`
(built and loaded by the same handler as `vault.pp`), which allows
`logrotate_t` to rotate the `vault_log_t` audit log (KNOWN_ISSUES #41).
Ports 8200-8203 are labeled `vault_cluster_port_t` (`vault_selinux_ports`;
8203 is the implicit cluster listener of the 8202 listener).

#### Vault Logging and Audit Channels

| Channel                | What                                               | Where / retention                                                 |
|------------------------|----------------------------------------------------|-------------------------------------------------------------------|
| Operational server log | Vault stdout/stderr (`log_level = info`)           | journald (`journalctl -u vault`), persistent, 2 GiB cap           |
| Audit device `file/`   | Every request/response, HMAC'd, JSON, one per line | `/var/log/vault/audit.log`, logrotate daily, 30 kept, compressed  |
| Audit device `syslog/` | Same events, facility `AUTH`, tag `vault-audit`    | journald (`journalctl -t vault-audit`); records > ~2 KB are split |

Two audit devices give redundancy: Vault refuses requests only when
**every** enabled audit device fails, and the copies live in separate
stores (file vs journal). The file device is canonical (complete JSON
per line); Vault's syslog writer splits records larger than ~2 KB into
consecutive entries (KNOWN_ISSUES #45).

#### PKI Roles

The intermediate CA issues leaf certificates through 5 distinct PKI
roles. The server and client-auth roles use `allow_any_name: true` and
`enforce_hostnames: false` because the Common Name field carries a
descriptive identity string (e.g., "HashiCorp Vault", "Nginx Gateway",
"jayissi - VaultPass"), not a hostname. Actual hostname validation
happens via SANs; modern TLS (RFC 6125) uses SANs exclusively for
hostname matching. The `nginx-proxy-client` role uses
`allow_any_name: false` to restrict issuance to the configured CN
only (CAB reviewer R1 recommendation).

| PKI Role                 | Purpose                      | CN Example             | Key Flags                                             | TTL   |
|--------------------------|------------------------------|------------------------|-------------------------------------------------------|-------|
| `vault-server`           | Vault API TLS                | HashiCorp Vault        | `server_flag: true`                                   | 2160h |
| `nginx-gateway`          | Nginx reverse proxy TLS      | Nginx Gateway          | `server_flag: true`                                   | 2160h |
| `client-auth`            | TLS client cert (VaultPass)  | jayissi - VaultPass    | `client_flag: true`, ClientAuth                       | 72h   |
| `nginx-proxy-client`     | Backend mTLS (Nginx → Vault) | Nginx Proxy Client     | `client_flag: true`, ClientAuth                       | 2160h |
| `bastion-gateway-client` | Bastion → SSH gateway mTLS   | Bastion Gateway Client | `client_flag: true`, ClientAuth, `OU=Bastion Gateway` | 720h  |

All five roles inherit `vault_pki_key_type: ec` /
`vault_pki_key_bits: 384` (P-384) from defaults.

#### Vault Agent Templates

Vault Agent manages 5 certificate/credential templates using the
single-`pkiCert` pattern (one API call produces cert + CA + key in a
combined output, then a command hook splits them into individual files):

| Template                    | PKI Role / Engine                  | Destination                                     | Perms | Split Command                         |
|-----------------------------|------------------------------------|-------------------------------------------------|-------|---------------------------------------|
| `leaf-combined.tpl`         | `pki_int/issue/vault-server`       | `/etc/vault.d/certs/` (via split)               | 0400  | `vault-agent-split-cert`              |
| `proxy-combined.tpl`        | `pki_int/issue/nginx-gateway`      | `/etc/nginx/certs/` (via split)                 | 0400  | `vault-agent-split-proxy-cert`        |
| `proxy-client-combined.tpl` | `pki_int/issue/nginx-proxy-client` | `/etc/nginx/certs/` (via split)                 | 0400  | `vault-agent-split-proxy-client-cert` |
| `client-auth-combined.tpl`  | `pki_int/issue/client-auth`        | `/opt/vault/agent-run/client-auth-combined.tmp` | 0400  | `vault-agent-split-client-cert`       |
| `breakglass-ssh-cert.tpl`   | `ssh-ca/sign/breakglass`           | `/etc/vault.d/certs/breakglass-cert.pub`        | 0444  | *(none — output is the signed cert)*  |

The break-glass SSH cert template reads the admin's Ed25519 public key
from `/etc/vault.d/certs/breakglass-admin-pubkey.pub` — a
vault-readable path populated by Ansible from the admin's
`authorized_keys`. The template **cannot** read directly from
`~/.ssh/id_ed25519.pub` because the admin's home directory has `0700`
permissions and the `vault` service account cannot traverse it.

### proxy

Nginx reverse proxy serving `https://vault.internal` (port 443) proxied
to Vault on port 8202 via backend mTLS. The dedicated Vault listener
on port 8202 requires a client certificate
(`tls_require_and_verify_client_cert = true`); Nginx presents the
`nginx-proxy-client` PKI-issued cert via `proxy_ssl_certificate` and
`proxy_ssl_certificate_key` in all three vhost templates (vault-proxy,
vault-status, vault-ssh-gateway). Uses a separate PKI-issued server
certificate (vault.internal SAN only) for the frontend TLS termination.
Cert rotation handled by a systemd path unit watching for file changes
(see [ADR-0003](decisions/ADR-0003-cert-rotation-path-units.md)).

#### Dual-Listener Architecture (Vault Ports 8200 / 8202)

Vault exposes two TCP listeners on the loopback interface, each with
a distinct trust model:

| Port | Listener Purpose          | Client Cert Required | Consumers                     |
|------|---------------------------|----------------------|-------------------------------|
| 8200 | CLI / Vault Agent / Admin | No                   | `vault` CLI, Vault Agent, API |
| 8202 | Nginx Reverse Proxy       | Yes                  | Nginx only                    |

Port 8202 was chosen because port 8201 is already reserved for Vault
Raft cluster communications. The 8202 listener uses the same server
TLS certificate as 8200 but adds
`tls_require_and_verify_client_cert = true` with `tls_client_ca_file`
pointing to the Intermediate CA. Only Nginx — presenting its
`nginx-proxy-client` certificate — can connect. This prevents any
process that reaches the loopback from impersonating the proxy
without a valid client certificate.

Forwarded-header trust (`x_forwarded_for_authorized_addrs`,
`x_forwarded_for_client_cert_header`, `..._decoders`) exists **only on
8202**. Every local process connects from 127.0.0.1, so trusting those
headers on 8200 let any local process present a forged `X-Client-Cert`
(the public half of a real user certificate) and log in through cert
auth without the private key (review finding E-02). On 8202 the header
is only honoured after the TLS handshake has proven the caller holds
the Nginx proxy-client key. Regression test T-01 in
`tests/security-test.sh` sends exactly that forged request to 8200.

Ansible validates Vault's TLS certificate on every API call (`ca_path`,
KNOWN_ISSUES P24) against `api-trust.pem`, a bundle assembled from the
certificates on disk (saved bootstrap cert, Root CA, Intermediate CA,
current server chain; `roles/vault/tasks/_api_trust.yml`). A bundle is
needed because during a first deploy Vault serves the bootstrap cert,
then an Agent-issued chain (Vault Agent reloads Vault before
`tls_production.yml` runs), then the production chain; ansible-core's
`ssl.create_default_context()` enables partial-chain verification on
Python 3.13+, so the Intermediate CA is a valid anchor before
`root.crt` exists.

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
  `https://127.0.0.1:8200` using the system CA trust bundle.
  The `pam_exec` configuration is written directly into
  `/etc/pam.d/sshd` (replacing `auth substack password-auth`), **not**
  as a standalone `/etc/pam.d/vault-ssh-helper` service file — sshd
  never references custom PAM service names; it always uses the `sshd`
  PAM stack. The vault-ssh-helper log file must be pre-created because
  sshd's pre-auth worker runs unprivileged and cannot create files in
  `/var/log/`.
- **nsswitch.conf** — hosts line override (post-authselect) to
  preserve mDNS resolution:
  `files mdns_minimal [NOTFOUND=continue] myhostname dns` (an mDNS miss
  falls through to Unbound -- KNOWN_ISSUES P21; written from the single
  `auth_nsswitch_hosts` variable by both the dns and auth roles)
- **pam_access** — `/etc/security/access.conf` from `auth_access_rules`:
  root locally, the admin locally and from `ssh_allowed_sources`, cron,
  then `-:ALL:ALL` default deny (gates SSH, sudo, su, GDM and cron)
- **pwhistory** — `remember = 24` + `enforce_for_root`
  (CIS 5.3.3.3.1); **su** restricted to `wheel` via `pam_wheel`
  (CIS 5.2.7)
- **vault-ssh-helper trust** — pinned to a copy of the Vault Root CA
  (`/etc/vault-ssh-helper.d/vault-ca.pem`) and `allowed_roles = "daily"``
- **SELinux Option A** — `sshd-vault-ssh-helper.te` (v1.2.0) allows
  **both** `sshd_t` and `sshd_session_t` to connect to
  `vault_cluster_port_t` (port 8200) for OTP validation, plus grants
  `sshd_session_t` file `open` + `append` on `var_log_t` for the log
  file. Option B (dedicated `vault_ssh_helper_t` domain transition) is
  the long-term plan, tracked in [KNOWN_ISSUES.md](KNOWN_ISSUES.md)
  backlog.

**Additional custom SELinux modules** in `roles/auth/files/selinux/`:

| Module                  | Version | Purpose                                                                   |
|-------------------------|---------|---------------------------------------------------------------------------|
| `fapolicyd-gdm.te`      | v1.1.0  | `sock_file` write + `unix_stream_socket` connectto for GDM integration    |
| `aide-efi.te`           | —       | `dosfs_t` filesystem `getattr` for AIDE `/boot/efi` scanning              |
| `auditctl-log.te`       | v1.2.0  | `dir` read + `file` open+read for auditctl access to audit logs           |
| `logind-usbguard.te`    | v1.2.0  | `getattr`+`open`+`read`+`search` on `usbguard_tmpfs_t` for logind         |
| `usbguard-gdm.te`       | v1.1.0  | `sock_file` write + connectto for machined and GDM userdb sockets         |
| `staff-systemd-user.te` | v1.0.0  | confined-admin noise: staff_t setattr own nodes; dontaudit creds/tmpfiles |
| `browser-tpm2.te`       | v1.1.0  | TPM2 device access extended to `sysadm_t` for Chrome/Firefox PKCS#11      |

> **Note:** The vault role deploys two additional SELinux modules from
> `roles/vault/files/selinux/`: `vault.te` (custom `vault_t` domain,
> see above) and `logrotate-vault.te` (allows `logrotate_t` to access
> `vault_log_t` files for audit log rotation, built by the vault
> policy handler).

Includes a forward-compatibility placeholder for FIDO2/U2F
(`auth_pam_u2f_enabled: false`).

### verification

Post-deployment read-only assertions: service health, TLS certificate
validity, Vault seal status, firewall rules, SELinux enforcing mode,
DNS resolution, and more.

`tasks/outcomes.yml` proves each control is **effective**, not merely
running (added after the Nov 2026 review found the firewall zone, DoT
and the CRL refresh all "active" but not in effect):

| Area     | Outcome asserted                                                                                                                                            |
|----------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Firewall | Interface and default zone are `FedoraWorkstation`; no open `ssh` service; no inbound 853; `dot-egress` active; `LogDenied=unicast`                         |
| DNS      | `vault.internal` → 127.0.0.1; bogus DNSSEC → SERVFAIL; signed zone → `ad`; dnsconfd forwarders are `dns+tls` only; RPZ and core blocklist both block        |
| Nginx    | Nothing on :80; CRL refresh not failed and `nextUpdate` in the future; CSP sink loopback-only                                                               |
| Vault    | 8200 listener has no `x_forwarded_for`; Vault and Nginx certificates carry `vault.internal`                                                                 |
| Auth/CIS | Agent forwarding off, pwhistory, su wheel-only, TMOUT, cron/at allow-lists, pam_access default deny, audit watches, screen lock                             |
| Platform | Crypto policy `DEFAULT:NO-SHA1-MAC` (no SSH SHA-1 MACs), kexec disabled, IPv6 RA ignored, every time source NTS-authenticated                               |
| Sandbox  | `ProtectHome`/`LimitCORE=0` on nginx, unbound, dnsconfd, vault-agent (no `NoNewPrivileges` on the first three -- KNOWN_ISSUES #39); exposure score reported |
| Warn     | AVC denials since boot; AppRole `secret_id` days remaining                                                                                                  |

`make validate` runs `make verify`, `make security-test` (on the VM,
including test T-01), `make bastion-test` (gateway mTLS from the
controller) and an idempotency re-run (`tests/idempotency.sh`) that
fails if `changed=` exceeds `VALIDATE_MAX_CHANGED`.

## Configuration Ownership

### dnsconfd vs. dns role

A clear ownership boundary exists between dnsconfd and the Ansible dns
role (see [ADR-0001](decisions/ADR-0001-unbound-dnsconfd-ownership.md)):

| Directive                    | Owner    | Mechanism                                                                                                         |
|------------------------------|----------|-------------------------------------------------------------------------------------------------------------------|
| DoT upstream servers         | dnsconfd | `static_servers` in `dnsconfd.conf`                                                                               |
| `resolv.conf`                | dnsconfd | Managed symlink                                                                                                   |
| `tls-cert-bundle`            | dnsconfd | `certification_authority` pushes to Unbound runtime                                                               |
| Security/performance/privacy | dns role | `unbound.conf.j2` template                                                                                        |
| Site-local overrides         | dns role | `/etc/unbound/conf.d/*.conf` drop-ins                                                                             |
| RPZ zones                    | dns role | Direct Unbound `conf.d` (not dnsconfd); see [ADR-0004](decisions/ADR-0004-rpz-via-unbound-native-not-dnsconfd.md) |

### Vault cert rotation

Cert rotation uses systemd path units (`PathModified`) instead of
cron or timer+inotifywait (see
[ADR-0003](decisions/ADR-0003-cert-rotation-path-units.md)):

- `vault-cert-reload.path` watches `/etc/vault.d/certs/server-chain.crt`
- `nginx-cert-reload.path` watches the proxy TLS cert

When Vault Agent writes a new certificate, the path unit triggers the
corresponding reload service immediately. The break-glass SSH cert
also auto-renews via Vault Agent's `template` stanza (written to
`/etc/vault.d/certs/breakglass-cert.pub`); the SSH CA key rotation
runbook in [OPERATIONS.md](OPERATIONS.md) covers the **CA key itself**,
not individual certificate renewal.

### Browser enterprise policies

Chrome enterprise policies are owned by the **dns** role
(`roles/dns/tasks/configure.yml`) and are limited to: managed
bookmarks (URLs default to `?with=cert` for TLS cert auth), DNS
security (DoH disabled), and `AutoSelectCertificateForUrls` for
automatic client certificate selection. Chrome **no longer carries
extension policies** — uBlock Origin and VaultPass are MV2-only and
Chrome 139+ removed MV2 support entirely. Firefox owns **all**
extension policies (uBlock Origin + VaultPass) via the **vault**
role's `browser_trust.yml`, which also sets
`security.default_personal_cert = "Select Automatically"` to suppress
client certificate prompts for VaultPass extension fetch calls.

## OpenSSH Privilege Separation on Fedora 44

Fedora 44 ships OpenSSH 10.2p1, which re-architected privilege
separation into two distinct SELinux domains:

| Domain           | Process        | Role                                                 |
|------------------|----------------|------------------------------------------------------|
| `sshd_t`         | `sshd`         | Listener — binds port 22, accepts connections        |
| `sshd_session_t` | `sshd-session` | Per-connection session handler — runs PAM auth stack |

This split is critical for SELinux module work targeting sshd PAM
extensions (e.g., `vault-ssh-helper` via `pam_exec.so`). The PAM auth
stack — where `vault-ssh-helper` runs — executes in `sshd_session_t`,
**not** `sshd_t`. Confirmed via runtime testing: the AVC from the
first real end-to-end OTP login showed
`scontext=...:sshd_session_t`, `comm="sshd-session"`.

The `sshd-vault-ssh-helper.te` module (v1.2.0) covers **both**
domains: `sshd_t` gets `name_connect` to `vault_cluster_port_t`, and
`sshd_session_t` gets `name_connect` plus file `open` + `append` on
`var_log_t` for logging.

## vault-agent-secret Self-Healing

The `vault-agent-secret.service` oneshot provisions the AppRole
`secret_id` file that `vault-agent.service` consumes for
authentication. `RemainAfterExit` was intentionally **removed** from
this unit.

**Why:** The Vault Agent `auto_auth` block is configured with
`remove_secret_id_file_after_reading = true` — the plaintext
`secret_id` file is consumed and deleted after the first successful
authentication. With `RemainAfterExit=true`, systemd marked the
oneshot as "active (exited)" permanently after the first boot. A
subsequent `systemctl restart vault-agent` (e.g., from an Ansible
handler) saw the `Requires=` dependency as already satisfied and never
re-ran `ExecStart`, leaving `vault-agent` with no `secret_id` file and
stuck in a permanent "no known secret ID" auth retry loop.

Without `RemainAfterExit`, the unit returns to "inactive" after each
run, so systemd's `Requires=`/`Before=` ordering re-triggers the
decrypt oneshot fresh on every subsequent start of
`vault-agent.service`.

**Contrast with `vault-unseal.service`:** The unseal service correctly
uses `WantedBy=vault.service` and works even with `RemainAfterExit`
because the unseal operation is idempotent — re-running it on an
already-unsealed Vault is a no-op, not a failure. The `secret_id`
provisioning is **not** idempotent in the same way: the file it
produces gets deleted by the consumer.

## Variable Management

- **Non-sensitive variables**: single source of truth in
  `inventory/group_vars/all/main.yml`
- **Sensitive variables**: `inventory/group_vars/all/vault.yml`
  (encrypted with `ansible-vault`)
- Galaxy roles are gitignored; install via `make venv` or `make galaxy`

## Lint Infrastructure

The `collections/` vendored directory must be excluded across **all**
tool configurations to prevent lint tools from scanning Galaxy
collection internals:

| Tool              | Exclusion Mechanism                                   |
|-------------------|-------------------------------------------------------|
| yamllint          | `lint/.yamllint.yml` `ignore` directive               |
| ruff              | `pyproject.toml` `[tool.ruff]` `exclude`              |
| pyright           | `pyproject.toml` `[tool.pyright]` `exclude`           |
| markdownlint-cli2 | `lint/.markdownlint-cli2.yaml` `ignores`              |
| codespell         | `pyproject.toml` `[tool.codespell]` `skip`            |
| checkov           | `lint/.checkov.yaml` `skip-path`                      |
| ansible-lint      | `.ansible-lint` `exclude_paths` (profile: production) |

**Two lint entry points:**

- `make lint` -- fast local loop. Builds the Podman image and runs
  `lint/lint-all.sh` against the bind-mounted checkout
  (`-v $(CURDIR):/workspace:z`). It auto-fixes first (ruff + table
  alignment), then runs all 19 checks (including
  `ansible-playbook --syntax-check`).
- `make ci` -- **dry run of GitHub Actions before you push**
  (`lint/ci-local.sh`). Snapshots exactly what would be pushed
  (`git ls-files --cached --others --exclude-standard`: tracked files
  with uncommitted edits plus new non-ignored files), builds the image
  from that snapshot with a cache-busting build arg so the lint tools
  are as fresh as CI's, and runs `lint-all.sh --check` (no auto-fix)
  with **no bind mount** and freshly installed Galaxy content. Use it
  before every push; it catches failures (e.g. ansible-lint
  `risky-file-permissions`) that a dirty working tree can hide.

Shell scripts under `tests/` and `lint/` are in the ShellCheck, shfmt
and codespell scopes in CI, `lint-all.sh` and pre-commit alike. The
pre-commit `shfmt`, `selint` and `hadolint` hooks call host binaries
(`sudo dnf install shfmt selint hadolint`, the packages CI uses).
The lint venv lives at `/opt/.venv` inside
the image — outside `/workspace` — so it is never shadowed by the
bind-mount (the host's own `.venv/` contains only `ansible-core`, not
the lint toolchain). CI (`.github/workflows/lint.yml`) runs every tool
directly in verify-only mode and never auto-fixes or mutates a PR
branch.

## Nginx Security Layers

The Nginx reverse proxy implements a 6-layer defense-in-depth
architecture for traffic reaching Vault through `https://vault.internal`:

| Layer | Name                  | Controls                                                                                                                                                                                                                                                                       |
|-------|-----------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1     | Network perimeter     | Interface bound to the `FedoraWorkstation` DROP zone (default zone); SSH and 8443 only from `ssh_allowed_sources` / `bastion_ip`; Vault on loopback only; Nginx on `127.0.0.1:443`; nothing on :80 (project-owned `nginx.conf`)                                                |
| 2     | TLS + identity        | `ssl_verify_client optional` with CA chain validation, active dual-CRL revocation checking (`ssl_crl` — Intermediate + Root CA with `nextUpdate` staleness, fail-closed), ECDSA-only cipher suite, session tickets off                                                         |
| 3     | HTTP security         | HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy, `Cache-Control: no-store` + `Pragma: no-cache`, CSP report-only with `report-uri /csp-report`, `server_tokens off`                                                                         |
| 4     | Proxy trust           | `X-Client-Cert` set from the verified handshake (stripped on the gateway), `X-Forwarded-For`/`X-Real-IP` from `$remote_addr`, backend mTLS to Vault `:8202`; forwarded-header trust exists only on 8202 (not 8200)                                                             |
| 5     | Vault authorization   | `auth/cert/login` via forwarded cert, ACL policies (`vaultpass`: `default/` read-only + `vaultpass-user-<user>`: own folder CRUD; role per CN), token TTLs (1h idle / 24h max)                                                                                                 |
| 6     | Operational assurance | Structured JSON access log (`vault_mtls_json`: cert fingerprint/DN/serial, TLS protocol/cipher, `$uri` without query string), CSP violation log, CRL hourly refresh ordered after Vault unseal, `nginx -t` (via `systemd-run`) before every reload, systemd sandboxing drop-in |

Rate limiting applies at Layer 3: auth endpoints at `5r/s`, API
endpoints at `30r/s`, connection limit of `20/IP`. The default-deny
catch-all vhost returns `444` (connection closed) for any request
with an unrecognized `Host` header.
