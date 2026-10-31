# Documentation Index

This directory contains detailed documentation for the
ansible-workstation-firstboot project.

## Contents

| Document                           | Description                                                                                                                                     |
|------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Service responsibilities, config ownership boundaries, and playbook phase ordering                                                              |
| [KNOWN_ISSUES.md](KNOWN_ISSUES.md) | Troubleshooting knowledge base -- symptoms, root causes, validated fixes, and future work backlog                                               |
| [OPERATIONS.md](OPERATIONS.md)     | Operational runbooks -- bastion enrollment, SSH CA key rotation, VaultPass setup, browser cert auto-select, AIDE re-baseline, P-384 CA rotation |
| [decisions/](decisions/)           | Architectural Decision Records (ADRs) in MADR format                                                                                            |

## Architectural Decision Records

| ADR                                                                   | Title                                                                | Status   |
|-----------------------------------------------------------------------|----------------------------------------------------------------------|----------|
| [ADR-0001](decisions/ADR-0001-unbound-dnsconfd-ownership.md)          | Unbound/dnsconfd config ownership split                              | Accepted |
| [ADR-0002](decisions/ADR-0002-vault-selinux-policy.md)                | Vault SELinux policy design                                          | Accepted |
| [ADR-0003](decisions/ADR-0003-cert-rotation-path-units.md)            | Cert rotation via systemd path units                                 | Accepted |
| [ADR-0004](decisions/ADR-0004-rpz-via-unbound-native-not-dnsconfd.md) | RPZ via Unbound-native config, not dnsconfd                          | Accepted |
| [ADR-0005](decisions/ADR-0005-vault-ssh-otp-ca.md)                    | Vault SSH secrets engine — OTP primary + Ed25519 CA break-glass      | Accepted |
| [ADR-0006](decisions/ADR-0006-ssh-credential-gateway.md)              | Narrowly-scoped SSH credential gateway                               | Accepted |
| [ADR-0007](decisions/ADR-0007-tls-client-cert-vaultpass-oidc.md)      | TLS client cert auth with TPM2-bound P-384, Vault OIDC for VaultPass | Accepted |

## Related Files

- [README.md](../README.md) -- project overview and quickstart
- [SECURITY.md](../SECURITY.md) -- vulnerability reporting and security model
- [CONTRIBUTING.md](../CONTRIBUTING.md) -- development setup and workflow
- [CHANGELOG.md](CHANGELOG.md) -- release history
