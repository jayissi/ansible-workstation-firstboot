# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
