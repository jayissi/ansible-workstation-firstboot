# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- VaultPass per-user folders: `vault_vaultpass_users` creates a
  read/write `secret/vaultPass/<user>/` folder, a policy and a CN-mapped
  cert role per user (plus an Agent-issued client cert synced into the
  browsers of users with a Linux account); shared `default/` is now
  read-only for VaultPass users and curated by Vault admins
  (KNOWN_ISSUES #52)
- `vault-approle-expiry-check` daily timer: warns in the journal and
  login banner when the Vault Agent AppRole `secret_id` has fewer than
  14 days left (fails the unit below 7). Ansible records the expiry on
  every run; verification asserts it matches Vault (KNOWN_ISSUES #51)
- `vault-browser-cert-sync` (+ `.path` on `client.crt`, 15-min `.timer`):
  re-imports the Agent-renewed client certificate into Chrome and every
  Firefox profile, so browser TLS-certificate login survives the 72h
  renewal and Firefox profiles created after the deploy
  (KNOWN_ISSUES #50); replaces the inline import that killed browsers and wiped
  `~/.pki/nssdb` on every run
- `make ci`: local dry run of the GitHub Actions lint workflow
  (`lint/ci-local.sh`) -- lints a clean snapshot of what would be pushed
  with fresh tool versions, no auto-fix, no bind mount;
  `lint-all.sh --check` mode and an `ansible-playbook --syntax-check`
  step
- `make validate`: outcome-based post-deploy validation
  (`roles/verification/tasks/outcomes.yml`), `make bastion-test`
  (`tests/bastion-test.sh`) and `make idempotency`
  (`tests/idempotency.sh`); security test T-01 (forged
  `X-Client-Cert` sent directly to Vault 8200 must not yield a token)
- SSH gateway bastion mutual TLS: PKI role `bastion-gateway-client`,
  certificate issued to the controller's gitignored `.bastion/`,
  `OU=Bastion Gateway` allow-list, CRL-checked (KNOWN_ISSUES P26)
- SSH gateway `Host` allow-list closing unknown names with 444 (P28,
  adapted), `POST`/`PUT`-only credential paths (P27)
- Structured JSON access logs `vault_mtls_json` (P31); CSP
  `report-uri /csp-report` with a loopback-only sink and JSON log (P29);
  `Cache-Control: no-store` + `Pragma: no-cache` (P32)
- firewalld `dot-egress` policy: outbound tcp/853 only to the approved
  DoT upstreams (P16); `LogDenied=unicast`
- Independent core `local-zone` blocklist (HaGeZi TIF mini) active
  alongside RPZ, with de-duplication and an empty-download guard (P22)
- systemd sandboxing drop-ins for nginx, unbound and dnsconfd; hardened
  vault-agent unit (`CapabilityBoundingSet=CAP_IPC_LOCK` only, `LimitCORE=0`, `ProtectHome`) (P23)
- AppRole `secret_id` lifecycle: 90-day TTL, loopback-bound, automatic
  rotation below 30 days, `make vault-rotate-secret-id`
- CIS session controls: `TMOUT` from `common_shell_timeout` (default
  3600 s), cron/at allow-lists, GNOME screen lock + GDM banner; su
  restricted to `wheel`; `pam_access` default-deny rules; pwhistory
  `remember = 24` actually written
- Audit watches on `/etc/pam.d`, `/etc/sssd`, `/etc/authselect`,
  `/etc/firewalld`, `/etc/systemd/system`, `/etc/polkit-1`,
  `/usr/local/bin`, `/etc/sysconfig`, `/etc/vault-agent.d`,
  `/etc/crypto-policies`, `/etc/dnsconfd.conf`
- ADR-0008 (`.internal` namespace);
  `inventory/group_vars/all/vault.yml.example`

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
- CRL revocation checking enabled (`ssl_crl`) with dual-CRL fetch
  (Intermediate + Root CA), `nextUpdate` staleness check with
  fail-closed behavior, CRL backup and rollback on `nginx -t` failure
- Automated security regression test suite (`make security-test`)
  with negative assertions (unknown host, TLS 1.1, oversized body,
  SSH gateway path restriction, header injection) and positive
  assertions (health endpoint, Vault UI, SSH gateway)
- Backend mutual TLS via dedicated Vault listener on port 8202 with
  `tls_require_and_verify_client_cert = true`; new
  `nginx-proxy-client` PKI role with ClientAuth EKU; Vault Agent
  auto-rotation
- `limit_req_status 429` for proper HTTP 429 on rate-limited requests
  (Nginx defaults to 503)
- CAB red-lit items added to backlog (Priorities 24–32)

### Fixed

- `secret/tls/vault` / `secret/tls/nginx` now follow every Vault Agent
  renewal: the split scripts publish the renewed public cert with the
  Agent's own token (file sink, policy `vault-agent-tls-publish`);
  `secret/tls/ca` renamed `secret/tls/ca_bundle` (#57)
- `vault-admin-readonly`: could read `secret/tokens/admin` (privilege
  escalation to admin) but could not list KV v2 secrets; now
  `secret/metadata/*` read/list and an explicit deny on
  `secret/*/tokens/*` (#56)
- Daily-use tokens: every deploy created a new `admin-daily` /
  `monitoring-readonly` token and never revoked the old one (27 live
  admin tokens). Now one periodic token per purpose is renewed, replaced
  only when invalid (old one revoked); strays are revoked (#53)
- `secret/tls/*`: replaced the stale `tls/server` copy (incl. a private
  key) and `tls/root-ca` with public-only `tls/ca_bundle`, `tls/vault`,
  `tls/nginx`, written only when changed (#54)
- VaultPass placeholders now exist only in empty folders (#55)
- GDM greeter ran a full GNOME desktop at boot without a password:
  the new CIS session task created a partial `/etc/dconf/profile/gdm`
  that shadowed the vendor profile (`greeter-dconf-defaults`); the
  partial file is removed and a verification assertion guards it
  (KNOWN_ISSUES #49)
- Post-reboot sweep (KNOWN_ISSUES #41-#48): `logrotate-vault` SELinux
  module was never compiled/loaded, so Vault audit-log rotation always
  failed (module 1.1 built by the vault policy handler); Vault's
  implicit 8203 cluster listener (port+1 of 8202) was denied bind
  (`vault_selinux_ports` labeled via `community.general.seport`);
  tmpfiles `e` never removed Agent cert/key bundles at boot (now `r`)
- `DEFAULT:NO-SHA1` rejected Microsoft's SHA-1-bound VS Code repo key
  and left SSH SHA-1 MACs enabled; replaced by custom
  `DEFAULT:NO-SHA1-MAC`, with a verification assertion for SSH MACs
- New USBGuard/logind/GDM AVC variants (`logind-usbguard` 1.2.0,
  `usbguard-gdm` 1.1.0) and `staff_t` systemd --user setattr noise
  (`staff-systemd-user` 1.0.0); `dontaudit` for the Vault Agent split
  scripts' awk `isatty()` ioctl probe (`vault.te` 1.5.0)
- Verification AVC check always reported 0: `ausearch` read Ansible's
  stdin pipe instead of the audit logs (now `--input-logs`, plus a
  per-denial summary); the Phase 0 `/root/.ansible/tmp` fix ran plain
  `sudo` (staff_t) and was silently denied (now sysadm_r when confined)
- pre-commit: codespell hook passed `--config pyproject.toml` (INI
  parser, broke on multi-line TOML arrays) -> `--toml`; `hadolint-docker`
  hook needed the docker CLI and ignored `lint/.hadolint.yaml` -> system
  `hadolint --config lint/.hadolint.yaml`, same as CI
- `lint/.secrets.baseline` stamped `1.5.55` by an unpinned
  `detect-secrets scan` made the pinned v1.5.0 hook rewrite it on every
  commit; normalized to the hook version and stale entries pruned
- Hardened firewall zone was never bound to the interface (stayed in
  `public`, SSH open to any source): zone now bound and default, stock
  `ssh` service removed so only the bastion rich rule admits SSH
- DNS-over-TLS was never active: the role wrote
  `/etc/dnsconfd/dnsconfd.conf`, but dnsconfd reads `/etc/dnsconfd.conf`
- Vault port 8200 trusted forwarded client-certificate headers from any
  local process (cert-auth login without the private key); header trust
  now exists only on the mTLS-protected 8202 listener
- SSH gateway passed client-supplied `X-Client-Cert` / `X-Forwarded-For`
  to Vault; now stripped/overwritten
- CRL refresh raced Vault unseal at boot and left an expired CRL;
  unit now ordered after `vault-unseal.service` with a bounded health wait
- `nginx -t` failed under the confined admin (`sysadm_t`) because of the
  stock `listen 80` server; project-owned `nginx.conf` (no :80) and
  validation via `systemd-run` in nginx's own domain
- Audit watch pointed at `/var/run/faillock` while faillock writes to
  `/var/log/faillock`
- Fresh installs: Vault started with the HashiCorp RPM's default
  `vault.hcl`; auditd failed on a not-yet-created watched directory
- dnsconfd crashed once its config was actually read: `syslog_log` takes
  a destination string, not `yes` (now `journal_log: yes`)
- `NoNewPrivileges` in the nginx/unbound/dnsconfd drop-ins blocked their
  SELinux domain transitions (no `nnp_transition` in the Fedora policy);
  removed from those drop-ins
- dns role could not repair a broken resolver: root hints are now only
  downloaded when missing (the timer refreshes them)
- AppRole `secret_id_ttl` was capped at 32 days by the mount's default max
  lease TTL; the `approle` mount is now tuned to the intended lifetime
- Vault API TLS validation follows the certificate Vault is actually
  serving (bootstrap, Agent-issued, production) via an on-disk trust
  bundle of CA certificates (`_api_trust.yml`)
- vault-agent could not start with an empty `CapabilityBoundingSet`
  (`/usr/bin/vault` carries the file capability `cap_ipc_lock+ep`)
- Core blocklist download returned 403 (jsDelivr hosts path); now the
  GitHub domains-only feed, the update script accepts both hosts and
  domains-only formats, and a header-only list is re-fetched
- `make security-test` ran as root in the confined `staff_t` domain on
  hardened hosts and could not read certificates or logs; it now
  transitions to `sysadm_t`

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

- Service hostnames `vault.local` / `status.vault.local` /
  `vault-ssh-gateway.local` → `.internal` (ADR-0008, KNOWN_ISSUES P14),
  defined once in the inventory; CRL update script is now a template
- Every Vault API call validates TLS (`ca_path`: bootstrap certificate,
  then production Root CA) instead of `validate_certs: false` (P24)
- DoT upstreams from `dns_dot_upstreams`; Google removed (P15); QNAME
  minimisation off in forwarder mode (P19); nsswitch
  `[NOTFOUND=continue]` from one shared variable (P21); explicit
  local-data TTL (P12); inbound 853 rule and no-op loopback rules removed
  (P10)
- Crypto policy `DEFAULT:NO-SHA1-MAC` (custom sub-policy: no SHA-1
  MACs); NTS-only time sources with
  `authselectmode require`; kexec disabled; IPv6 RA/redirects ignored;
  cockpit.socket masked; SSH `AllowAgentForwarding no`
- vault-ssh-helper pinned to the Vault Root CA and the `daily` role
- Chrome certificate auto-select issuer derived from
  `vault_pki_organization`

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
- `proxy_backend_url` changed from `https://127.0.0.1:8200` to
  `https://127.0.0.1:8202` (dedicated proxy listener with required
  client cert)
- CRL update script rewritten for dual-fetch with hostname resolution
  consistency (`--resolve vault.local:8200:127.0.0.1`)
- All three proxy vhost templates (vault-proxy, vault-status,
  vault-ssh-gateway) now include `proxy_ssl_certificate` and
  `proxy_ssl_certificate_key` for backend client cert presentation

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
