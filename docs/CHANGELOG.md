# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- yamllint `brackets`/`braces: forbid: non-empty` — enforces
  block-style YAML sequences and mappings everywhere (Red Hat Ansible
  best practice), while still allowing bare `[]`/`{}` for empty
  collections since block-style has no syntax for an empty sequence
- Browser managed bookmarks ("Vault" and "Vault Status") in both
  Firefox and Chrome via enterprise policies, bookmark bar forced
  visible, visible in regular and private/incognito mode
- VaultPass and uBlock Origin extensions pinned to toolbar in both
  browsers via `default_area: "navbar"` (Firefox) and
  `toolbar_pin: "force_pinned"` (Chrome)
- `status.vault.local` DNS record and Nginx vhost proxying to
  Vault's `/v1/sys/health` endpoint for quick health checks
- Nginx re-encryption architecture with
  `x_forwarded_for_client_cert_header` for browser-based TLS client
  certificate authentication through the reverse proxy — Nginx
  validates the client cert, forwards it URL-encoded via
  `$ssl_client_escaped_cert`, and Vault reads it from the
  `X-Client-Cert` header for `auth/cert/login`
- HTTP security headers shared snippet (`security-headers.conf`):
  HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy,
  Permissions-Policy, CSP in report-only mode, X-Robots-Tag noindex
- TLS cipher hardening (`nginx-hardening.conf`): ECDSA-only cipher
  suite (`ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256`),
  `ssl_ecdh_curve secp384r1:X25519`, `ssl_session_tickets off`,
  `server_tokens off`
- Rate limiting on Vault auth (`5r/s`) and API (`30r/s`) endpoints,
  connection limits (`20/IP`), request timeouts
- Default-deny catch-all vhost (`default-deny.conf`) returning 444
  for unknown Host headers
- CRL lifecycle automation: hourly systemd timer fetches CRL from
  Vault PKI, validates with `openssl crl`, atomic deploy to
  `/etc/nginx/certs/client-ca.crl`, `nginx -t` guard before reload
- Certificate fingerprint access logging: per-vhost `vault_mtls` log
  format with cert fingerprint, DN, serial, and verify status
- `nginx -t` validation before every Nginx reload (prevents config
  errors from taking Nginx down)
- Firefox auto-select client cert policy
  (`security.default_personal_cert = "Select Automatically"`, locked)
  in enterprise policy — eliminates cert dialog that blocked VaultPass
  fetch calls
- Chrome auto-select client cert (`AutoSelectCertificateForUrls` with
  issuer filter `O=Local Lab Infrastructure`) via managed policy
- Managed bookmark URLs updated to default TLS cert auth via
  `?with=cert` query parameter (both browsers)
- `auth/token/revoke-self` capability added to vaultpass policy
  (enables clean VaultPass logout)
- `logrotate-vault.te` SELinux module allowing `logrotate_t` to
  access `vault_log_t` files for audit log rotation
- CRL bootstrap replaced `get_url` with `validate_certs: false` with
  `ansible.builtin.uri` using `ca_path` for proper TLS validation
  against private CA; URL changed to `vault.local:8200` to match
  cert SAN
- `devlog_t:unix_dgram_socket sendto` rule added to `vault.te` v1.4.0
  enabling Vault syslog audit backend under SELinux confinement
- `vault-syslog` SELinux fix integrated into main `vault.te`
  (v1.4.0): `devlog_t` type in require block, `write` permission on
  self `unix_dgram_socket`, `sendto` to
  `devlog_t:unix_dgram_socket`

### Fixed

- Lint container venv-shadowing bug: `make lint`'s auto-fix step
  bind-mounts the host checkout onto `/workspace`, which silently
  replaced the image's lint-toolchain venv with the host's own
  `ansible-core`-only venv (`ruff: command not found`). Moved the
  lint venv to `/opt/.venv`, outside `/workspace`, so no bind-mount
  can ever shadow it
- Converted ~30 flow-style YAML sequences/mappings (`[a, b]` /
  `{k: v}`) to block-style across task loop items, `.pre-commit-config.yaml`
  hook `args`, and Vault policy bodies, to satisfy the new yamllint
  rules
- Browser TLS client certificate auth: added `tls_client_ca_file` to
  Vault listener and `ssl_verify_client optional` to Nginx reverse
  proxy so browsers prompt for the TPM2-bound client certificate when
  using the Vault UI "TLS Certificates" login method
- Vault bookmark URL changed from `:8200` to `https://vault.local`
  (cert auth now works through Nginx re-encryption proxy in both
  Firefox and Chrome)
- VaultPass credential display: Firefox cert dialog prompted twice
  (page context vs extension `moz-extension://` origin), blocking
  VaultPass fetch calls with
  `NetworkError when attempting to fetch resource`. Fixed with
  `security.default_personal_cert = "Select Automatically"` Firefox
  enterprise policy
- Vault syslog audit backend: `vault_t` SELinux domain had zero
  `unix_dgram_socket` permissions for `devlog_t` target — journal
  socket write failed silently (no AVC audit record emitted when zero
  rules exist for an object class, confirmed via `sesearch` policy
  analysis and `semodule -DB` dontaudit removal). Fixed in `vault.te`
  v1.4.0. Ref: hashicorp/vault#31670 (same failure class, AppArmor
  on Ubuntu)
- Vault audit log rotation: SELinux `logrotate_t` domain blocked from
  accessing `vault_log_t` files. Fixed with `logrotate-vault.te`
  SELinux module + logrotate `copytruncate` + `su vault vault`
  directive

### Changed

- Refactored lint infrastructure: extracted the 18-tool lint chain
  from the Containerfile's inline CMD into `lint/lint-all.sh` (single
  entry point, shared constants for file lists, `run_linter` wrapper
  that runs all tools and reports a pass/fail summary instead of
  stopping at the first failure). `make lint` is now one `podman
  build` + one `podman run` instead of two of each. Deleted
  `lint/lint-fedora-native.sh` (absorbed into `lint-all.sh`).
  Makefile refactored with venv guards, path variables, and explicit
  activation. Containerfile slimmed with `--setopt=install_weak_deps=False`,
  `--no-cache-dir`, and `LABEL` metadata
- VaultPass policy renamed from `vaultpass-readonly` to `vaultpass`
  with full CRUD capabilities (`create, read, update, delete` on
  `secret/data/vaultPass/*`)
- Removed all Chrome extension policies (uBlock Origin and VaultPass
  are MV2-only; Chrome 139+ fully removed Manifest V2 support)
- uBlock Origin unpinned from Firefox navbar (runs in background, not
  force-pinned)
- Vault SELinux policy bumped to v1.4.0
- Logrotate vault-audit config uses `copytruncate` instead of
  `create` (avoids SELinux label issues on rotated files)

## [0.2.0] - 2026-10-30

### Added

- ECDSA P-384 (CNSA 2.0) PKI upgrade -- full-chain consistency across
  Root CA, Intermediate CA, and all leaf certificates
- TLS client certificate authentication as primary Vault auth method
  (TPM2-bound P-384 via PKCS#11, no userpass fallback)
- VaultPass browser extension + uBlock Origin in private mode for
  browser-based Vault credential access
- Vault OIDC Identity Provider scoped to `vaultpass` client only
  (`allowed_client_ids` not wildcard, ES384 signing key with 6h
  rotation, explicit issuer)
- Split Vault Agent policies: `vault-agent-tls` (cert renewal) +
  `vault-agent-auth` (AppRole auth)
- Break-glass SSH certificate auto-renewal with admin pubkey
  extraction to vault-readable path
- Secure Boot verification in preflight checks
- TPM2 PCR-bound unseal surviving vault.service restart
- Hardware-aware tuning: `hardware_tuning.yml` with rasdaemon on
  physical hosts, VM guests skip hardware-specific tasks
- 7 new SELinux modules: fapolicyd-gdm, aide-efi, auditctl-log,
  logind-usbguard, usbguard-gdm, browser-tpm2 (extended to
  `sysadm_t`), sshd-vault-ssh-helper v1.2.0 (`sshd_session_t`)
- SSH OTP PAM wiring directly into `/etc/pam.d/sshd` auth stack
  (replacing orphaned standalone PAM service file)
- vault-agent-secret self-healing: `RemainAfterExit` removed so
  AppRole `secret_id` re-provisioning fires on every restart
- Organization renamed to Local Lab Infrastructure
- ADR-0007: TLS client cert auth with TPM2-bound P-384 and Vault
  OIDC for VaultPass

### Fixed

- P-384 Root CA and Intermediate CA: added missing `key_bits`
  parameter to `pki/root/generate/internal` and
  `pki_int/intermediate/generate/internal` (Vault silently defaulted
  to P-256)
- SSH OTP 4-layer non-functionality: orphaned PAM file never wired
  into sshd, log file DAC preventing pre-auth worker writes, wrong
  SELinux domain (`sshd_t` vs Fedora 44's `sshd_session_t`), hidden
  `dontaudit`'d `open` permission (required `semodule -DB`)
- Break-glass SSH cert crash-loop: template hardcoded nonexistent
  `~/.ssh/id_ed25519.pub`; vault user blocked by 0700 home dir
- vault-agent-secret `RemainAfterExit` gap: oneshot stayed
  "active (exited)" permanently, preventing `secret_id`
  re-provisioning on restart
- AIDE baseline silent reset: `aide_init` static `true` replaced by
  dynamic `pre_tasks` gate on database existence
- `pam_unix` invalid `not_set_pass` option typo from untested
  orphaned PAM content
- Lint infrastructure 8-fix sweep: `collections/` vendored directory
  excluded across yamllint, ansible-lint, ruff, pyright,
  markdownlint-cli2, codespell, checkov, and CI workflow;
  `vault_pass.txt` placeholder in Containerfile CMD
- fapolicyd cache tuning for GDM socket access
- polkit reload handler correction
- TPM2 PKCS#11 `changed_when` false-positive suppressed

### Changed

- `vm_tuning.yml` renamed to `hardware_tuning.yml` (broader scope)
- mcelog removed and replaced by rasdaemon (mcelog deprecated upstream)
- `crypto_policies` reverted from `FUTURE` to `DEFAULT` (`FUTURE`
  rejects RSA 2048 end-entity certificates still common in external
  services)
- `aide_init` static `true` replaced by dynamic `pre_tasks` gate
  checking database existence before initialization

## [0.1.0] - 2026-10-29

### Added

- SSSD + PAM + Vault SSH secrets engine (OTP primary + Ed25519 CA break-glass)
- SSH credential gateway (narrowly-scoped Nginx vhost on port 8443)
- Auth role: authselect, faillock, pwquality, vault-ssh-helper, SELinux policy
- Vault audit devices (file + syslog)
- LAN DNS feature flag
- `SECURITY.md` -- vulnerability reporting policy and security model summary
- `CHANGELOG.md` -- project changelog in Keep a Changelog format
- `docs/` directory with documentation index, architecture guide, and
  known-issues troubleshooting knowledge base
- `docs/decisions/` with ADR-0001 through ADR-0006 capturing key
  architectural decisions (MADR format)

### Fixed

- Plymouth boot hang after LUKS unlock (`plymouth.enable=0` + `quiet` removal)
- Audit rules file-ordering (`99-` prefix renamed to `zz-`)
- LUKS verification false-negative under LVM
- SSH credential gateway TLS mismatch and notify handler
- Vault SELinux module idempotency check
- Multiple idempotency improvements (authselect, CA-trust, yum_repository)

### Changed

- Documentation and lint infrastructure cleanup
- `README.md` trimmed to under 150 lines; detailed content moved to
  `docs/` subdirectory
- `CHANGELOG.md` relocated from project root to `docs/`
