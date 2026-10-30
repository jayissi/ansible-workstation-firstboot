# ansible-workstation-firstboot

Vault-first, security-hardened Ansible project that automates first-boot
provisioning of a Fedora workstation with GUI. HashiCorp Vault CE installs
early as the secrets backbone, followed by 16 linux-system-roles for
comprehensive hardening. AIDE captures the final filesystem baseline last.

## Architecture

```text
Phase 0: Detect SELinux context (auto-sets sudo flags)

Phase 1: Bootstrap
  common     -> preflight (LUKS/TPM2), update, packages, USBGuard, banner
  dns        -> Unbound (DNSSEC + DoT + blocklist), dnsconfd, DoH lockdown
  avahi      -> hardened mDNS/DNS-SD
  vault      -> install, bootstrap TLS, init, PKI, Agent, browser trust,
                SSH secrets engine (OTP + Ed25519 CA break-glass),
                TLS client cert auth, OIDC Identity Provider, VaultPass
  proxy      -> Nginx reverse proxy (https://vault.local -> :8200),
                SSH credential gateway (:8443, OTP + CA paths only)

Phase 2: Harden (secrets from Vault)
  Tier 0     -> crypto_policies, timesync, tuned, hardware_tuning,
                kernel_settings, journald, bootloader, certificate, systemd
  Tier 1     -> sshd, auditd, tlog
  Tier 2     -> firewall, selinux, auth
  Tier 3     -> sudo (sysadm_r), fapolicyd (LAST)

Phase 3: Finalize
  aide       -> init database LAST (gated on database existence,
                captures hardened baseline)
  verify     -> read-only assertions

Phase 4: Reboot (conditional)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for service
responsibilities, configuration ownership boundaries, and tier ordering
rationale.

## Quickstart

```bash
git clone <repo-url>
cd ansible-workstation-firstboot

make setup    # Install controller RPM prerequisites
make venv     # Create venv, install ansible-core, download Galaxy roles

# Update target IP:
#   inventory/hosts.yml -> ansible_host
#   .ssh_config         -> Hostname

source .venv/bin/activate
ansible workstation -m ping   # Verify connectivity
make lint                     # Run all linters (Podman container)
make test                     # Syntax check
make deploy                   # Full deployment
make verify                   # Post-deploy assertions
```

## PKI Configuration

Default: **ECDSA P-384 (CNSA 2.0)**, consistent across Root CA,
Intermediate CA, and all leaf certificates. Set
`vault_pki_key_type: ed25519` for Ed25519.

```yaml
# inventory/group_vars/all/main.yml
vault_pki_key_type: ec        # "ec" (ECDSA P-384) or "ed25519"
vault_pki_key_bits: 384       # P-384 curve size (CNSA 2.0)
```

## Vault Access

Open a browser on the workstation: `https://vault.local`

```bash
sudo vault-admin status                        # Vault health + seal status
sudo vault-admin kv get secret/tokens/admin     # Admin token for UI login
```

`vault-admin` auto-decrypts the root token, trying TPM2+age first, then
passphrase fallback, then plaintext (first-run only).

## Security Summary

- GRUB2 password-protected, `audit=1`, LUKS full-disk encryption
- SSH: key-only, no root login, Ed25519, AllowUsers, banner,
  Vault OTP (verified end-to-end) + Ed25519 CA break-glass,
  credential gateway (:8443)
- Auth: TLS client cert primary (TPM2-bound P-384 via PKCS#11),
  authselect sssd profile, faillock, pwquality, pwhistory,
  vault-ssh-helper PAM integration, Vault OIDC Identity Provider
- Browser: VaultPass extension + uBlock Origin (private mode)
- DNS: DNSSEC + DoT (8 servers), ~76K blocklist, port 53 blocked,
  browser DoH bypass prevented
- Firewall: zone target DROP, service-specific allow rules only
- SELinux enforcing: `staff_u` admin, custom `vault_t` policy
- fapolicyd: SHA-256 integrity, RPM + trusted binaries only
- Vault CE: ECDSA P-384 (CNSA 2.0) TLS, full-chain consistency
  (Root CA → Intermediate CA → leaf), auto-rotating certs,
  TPM2-bound secrets, split policies (vault-agent-tls + vault-agent-auth)
- Self-healing: TPM2 auto-unseal survives vault.service restart,
  Vault Agent secret_id re-provisioning on restart,
  cert-rotation path-unit auto-reload
- Hardware-aware tuning: rasdaemon on physical hosts (mcelog removed,
  deprecated); VM guests skip hardware-specific tasks
- AIDE: daily integrity checks, baseline init gated on database
  existence (prevents silent resets), initialized after all hardening
- Auditd: 50 CIS/NIST/STIG-aligned rules, immutable config (`-e 2`)

See [SECURITY.md](SECURITY.md) for the full security model and
vulnerability reporting policy.

## Ansible Tags

```bash
ansible-playbook playbooks/site.yml --tags vault
ansible-playbook playbooks/site.yml --tags harden
ansible-playbook playbooks/site.yml --tags verify
ansible-playbook playbooks/site.yml --skip-tags aide
make vault-rotate-root-token   # Rotate root token (on-demand)
```

## Project Structure

```text
ansible-workstation-firstboot/
  ansible.cfg                    # Ansible configuration
  Makefile                       # Targets: help, setup, venv, lint, deploy, verify, etc.
  playbooks/site.yml             # Five-phase master playbook with tags
  inventory/
    hosts.yml                    # Target host (dynamic IP)
    group_vars/all/
      main.yml                   # All variables (single source of truth)
      vault.yml                  # Ansible Vault encrypted secrets
  roles/
    common/ dns/ avahi/ auth/    # Custom roles (7 total)
    vault/ proxy/ verification/
    requirements.yml             # Galaxy roles (gitignored after download)
  lint/                          # All linter configs + Podman container
  docs/                          # Architecture, known issues, ADRs
```

## Further Documentation

| Document                                     | Description                                     |
|----------------------------------------------|-------------------------------------------------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Service roles, config ownership, phase ordering |
| [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) | Troubleshooting knowledge base                  |
| [docs/decisions/](docs/decisions/)           | Architectural Decision Records (MADR)           |
| [docs/CONVENTIONS.md](docs/CONVENTIONS.md)   | Naming, style, and linter conventions           |
| [SECURITY.md](SECURITY.md)                   | Security model and vulnerability reporting      |
| [CONTRIBUTING.md](CONTRIBUTING.md)           | Development setup and workflow                  |
| [CHANGELOG.md](docs/CHANGELOG.md)            | Release history                                 |

## License

See [LICENSE](LICENSE) for details.
