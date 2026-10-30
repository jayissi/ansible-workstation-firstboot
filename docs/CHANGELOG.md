# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- yamllint `brackets`/`braces: forbid: non-empty` -- enforces
  block-style YAML sequences and mappings everywhere (Red Hat Ansible
  best practice), while still allowing bare `[]`/`{}` for empty
  collections since block-style has no syntax for an empty sequence

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

### Changed

- Removed the standalone `lint-fix` Makefile target; its auto-fix
  recipe (ruff + markdown-table-formatter) is now inlined directly
  into `lint`, which always auto-fixes then runs the full verify
  suite in one step. CI remains verify-only and never auto-fixes

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
