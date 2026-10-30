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
| 5     | `proxy`  | Nginx reverse proxy (`https://vault.local` → `:8200`), cert rotation via systemd path unit                                                                                            |

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
TLS (self-signed ECDSA P-384), server configuration, operator init
with age+TPM2 key encryption, internal PKI engine with Root and
Intermediate CA (ECDSA P-384, CNSA 2.0 compliant), 3 distinct PKI
roles, AppRole authentication, Vault Agent for automated cert rotation,
production TLS certificate swap, TLS client certificate authentication
with OIDC provider integration (`cert_auth.yml`), KV secret seeding
with readonly policy (`vaultpass.yml`), browser trust store
configuration (Root CA + VaultPass extension), and secrets backup to
KV.

Custom SELinux policy (`vault_t`) with `gen_tunable` booleans for
optional network access (see
[ADR-0002](decisions/ADR-0002-vault-selinux-policy.md)).

#### PKI Roles

The intermediate CA issues leaf certificates through 3 distinct PKI
roles. All roles use `allow_any_name: true` and
`enforce_hostnames: false` because the Common Name field carries a
descriptive identity string (e.g., "HashiCorp Vault", "Nginx Gateway",
"jayissi - VaultPass"), not a hostname. Actual hostname validation
happens via SANs; modern TLS (RFC 6125) uses SANs exclusively for
hostname matching.

| PKI Role        | Purpose                     | CN Example          | Key Flags                       | TTL   |
|-----------------|-----------------------------|---------------------|---------------------------------|-------|
| `vault-server`  | Vault API TLS               | HashiCorp Vault     | `server_flag: true`             | 2160h |
| `nginx-gateway` | Nginx reverse proxy TLS     | Nginx Gateway       | `server_flag: true`             | 2160h |
| `client-auth`   | TLS client cert (VaultPass) | jayissi - VaultPass | `client_flag: true`, ClientAuth | 72h   |

All three roles inherit `vault_pki_key_type: ec` /
`vault_pki_key_bits: 384` (P-384) from defaults.

#### Vault Agent Templates

Vault Agent manages 4 certificate/credential templates using the
single-`pkiCert` pattern (one API call produces cert + CA + key in a
combined output, then a command hook splits them into individual files):

| Template                   | PKI Role / Engine             | Destination                                     | Perms | Split Command                        |
|----------------------------|-------------------------------|-------------------------------------------------|-------|--------------------------------------|
| `leaf-combined.tpl`        | `pki_int/issue/vault-server`  | `/etc/vault.d/certs/` (via split)               | 0400  | `vault-agent-split-cert`             |
| `proxy-combined.tpl`       | `pki_int/issue/nginx-gateway` | `/etc/nginx/certs/` (via split)                 | 0400  | `vault-agent-split-proxy-cert`       |
| `client-auth-combined.tpl` | `pki_int/issue/client-auth`   | `/opt/vault/agent-run/client-auth-combined.tmp` | 0400  | `vault-agent-split-client-cert`      |
| `breakglass-ssh-cert.tpl`  | `ssh-ca/sign/breakglass`      | `/etc/vault.d/certs/breakglass-cert.pub`        | 0444  | *(none — output is the signed cert)* |

The break-glass SSH cert template reads the admin's Ed25519 public key
from `/etc/vault.d/certs/breakglass-admin-pubkey.pub` — a
vault-readable path populated by Ansible from the admin's
`authorized_keys`. The template **cannot** read directly from
`~/.ssh/id_ed25519.pub` because the admin's home directory has `0700`
permissions and the `vault` service account cannot traverse it.

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
  `files mdns_minimal [NOTFOUND=return] myhostname dns`
- **SELinux Option A** — `sshd-vault-ssh-helper.te` (v1.2.0) allows
  **both** `sshd_t` and `sshd_session_t` to connect to
  `vault_cluster_port_t` (port 8200) for OTP validation, plus grants
  `sshd_session_t` file `open` + `append` on `var_log_t` for the log
  file. Option B (dedicated `vault_ssh_helper_t` domain transition) is
  the long-term plan, tracked in [KNOWN_ISSUES.md](KNOWN_ISSUES.md)
  backlog.

**Additional custom SELinux modules** in `roles/auth/files/selinux/`:

| Module               | Version | Purpose                                                                |
|----------------------|---------|------------------------------------------------------------------------|
| `fapolicyd-gdm.te`   | v1.1.0  | `sock_file` write + `unix_stream_socket` connectto for GDM integration |
| `aide-efi.te`        | —       | `dosfs_t` filesystem `getattr` for AIDE `/boot/efi` scanning           |
| `auditctl-log.te`    | v1.2.0  | `dir` read + `file` open+read for auditctl access to audit logs        |
| `logind-usbguard.te` | v1.1.0  | `getattr`+`read` on `usbguard_tmpfs_t` for logind integration          |
| `usbguard-gdm.te`    | —       | `sock_file` write + `unix_stream_socket` connectto for GDM             |
| `browser-tpm2.te`    | v1.1.0  | TPM2 device access extended to `sysadm_t` for Chrome/Firefox PKCS#11   |

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

Chrome enterprise policies (DoH lockdown + VaultPass / uBlock Origin /
incognito enforcement) are entirely owned by the **dns** role
(`roles/dns/tasks/configure.yml`). The Firefox equivalent (VaultPass +
uBlock Origin) is owned by the **vault** role's `browser_trust.yml`.

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

| Tool              | Exclusion Mechanism                         |
|-------------------|---------------------------------------------|
| yamllint          | `.yamllint` `ignore` directive              |
| ruff              | `ruff.toml` `exclude`                       |
| pyright           | `pyrightconfig.json` `exclude`              |
| markdownlint-cli2 | `.markdownlint-cli2.jsonc` `ignores`        |
| codespell         | `.codespellrc` `skip` + `ignore-words-list` |
| checkov           | `.checkov.yml` `skip_path`                  |

**Single `make lint` target (one build, one run):** `make lint` builds
the Podman image and runs `lint/lint-all.sh` inside it against the
bind-mounted host checkout (`-v $(CURDIR):/workspace:z`). The script
auto-fixes first (ruff + table alignment), then runs all 18 linters
with a pass/fail summary. The lint venv lives at `/opt/.venv` inside
the image — outside `/workspace` — so it is never shadowed by the
bind-mount (the host's own `.venv/` contains only `ansible-core`, not
the lint toolchain). CI (`.github/workflows/lint.yml`) runs every tool
directly in verify-only mode and never auto-fixes or mutates a PR
branch.
