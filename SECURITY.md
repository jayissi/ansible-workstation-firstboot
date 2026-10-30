# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it
responsibly. **Do not open a public GitHub issue.**

1. Email the maintainer at the address listed in the repository contact info
   with a description of the vulnerability, steps to reproduce, and any
   relevant logs or screenshots.
2. Allow up to **72 hours** for an initial response.
3. Work with the maintainer to validate and remediate the issue before any
   public disclosure.

We follow a coordinated disclosure model: fixes are developed privately,
merged, and announced once a patched version is available.

## Security Model

This project deploys a defense-in-depth security posture on Fedora
workstations. The hardening stack is applied in dependency-aware tiers
(see `docs/ARCHITECTURE.md` for phase ordering).

### Key Security Components

| Component                  | Purpose                                                                                                                                                                                                                                                                                                                                                          |
|----------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **SELinux** (enforcing)    | Mandatory access control. Admin mapped to `staff_u`; system users to `unconfined_u` (GUI-safe). Custom policy modules for `vault_t`, DNS services, and `sshd_session_t` (Fedora 44 OpenSSH 10.2p1 privilege separation domain). Additional modules: fapolicyd-gdm, aide-efi, auditctl-log, logind-usbguard, usbguard-gdm, browser-tpm2 (extended to `sysadm_t`). |
| **fapolicyd**              | Application allowlisting. SHA-256 integrity verification; only RPM-installed and explicitly trusted binaries execute.                                                                                                                                                                                                                                            |
| **AIDE**                   | File integrity monitoring. Database initialized *last* after all hardening is complete, capturing the fully hardened baseline. Baseline init gated on database existence to prevent silent resets. Daily checks via systemd timer.                                                                                                                               |
| **USBGuard**               | USB device allowlisting. Blocks unauthorized USB devices at the kernel level.                                                                                                                                                                                                                                                                                    |
| **HashiCorp Vault CE**     | Secrets backbone. ECDSA P-384 (CNSA 2.0) TLS via internal PKI engine, consistent across Root CA, Intermediate CA, and all leaf certificates. Auto-rotating certificates; age+TPM2 encrypted unseal keys. Split policies: vault-agent-tls + vault-agent-auth.                                                                                                     |
| **TLS Client Cert Auth**   | Primary Vault authentication method. TPM2-bound P-384 client certificate via PKCS#11; no userpass fallback. Registered in Chrome and Firefox NSS databases.                                                                                                                                                                                                      |
| **VaultPass + uBlock**     | VaultPass browser extension for Vault credential access with uBlock Origin in private mode. Vault token obtained via OIDC flow (not direct grab).                                                                                                                                                                                                                |
| **Vault OIDC Provider**    | Vault as OpenID Connect Identity Provider. Scoped to `vaultpass` client only (`allowed_client_ids` not wildcard), ES384 signing key with 6h rotation, explicit issuer.                                                                                                                                                                                           |
| **Auth**                   | Authselect + PAM hardening (faillock, pwquality, pwhistory). vault-ssh-helper OTP validation via `pam_exec`. Custom SELinux policy for sshd-to-Vault connectivity (`sshd_session_t` domain).                                                                                                                                                                     |
| **SSH Credential Gateway** | Nginx vhost (:8443) exposing only `/v1/ssh-otp/creds/` and `/v1/ssh-ca/sign/` to the bastion. All other paths return 403.                                                                                                                                                                                                                                        |
| **Auditd**                 | Kernel audit framework. 50 CIS/NIST/STIG-aligned syscall rules covering file access, privilege escalation, and authentication events.                                                                                                                                                                                                                            |

### CIS/STIG Alignment

The hardening configuration targets alignment with:

- **CIS Fedora Linux Benchmark** -- filesystem, authentication, logging,
  network, and access-control recommendations
- **DISA STIG for Red Hat Enterprise Linux** -- applicable controls
  adapted for Fedora

Notable controls implemented:

- GRUB2 password protection with audit kernel parameter (`audit=1`)
- LUKS full-disk encryption (verified at playbook start)
- SSH hardened: key-only authentication, no root login, Ed25519 keys,
  `AllowUsers` restriction, security banner, Vault OTP (verified
  end-to-end) + Ed25519 CA break-glass
- DNS: DNSSEC + DNS-over-TLS, outbound plaintext DNS (port 53) blocked
- Firewall: zone target `DROP`, service-specific allow rules only
- Crypto policies: RHEL `DEFAULT` profile via `linux-system-roles.crypto_policies`
  (reverted from `FUTURE` -- `FUTURE` rejects RSA 2048 end-entity
  certificates still common in external services)
- Audit immutability (`-e 2`) for tamper resistance
- Faillock: account lockout after failed attempts (CIS 5.3.2.2 module
  enablement, CIS 5.3.3.1.x deny/unlock values)
- Pwquality: password complexity (CIS 5.3.3.2.2 minimum length = 14,
  minclass = 4)
- Pwhistory: password reuse prevention (CIS 5.3.3.3.1 remember = 24)
- pam_faillock: enabled via authselect `with-faillock` feature
  (CIS 5.3.2.2)

### Network Security

- All DNS queries use DNS-over-TLS (port 853); plaintext DNS is
  firewall-blocked
- Browser DoH bypass prevented via Firefox/Chrome enterprise policies
- Vault API accessible only on localhost (ports 8200/8201)
- SSH restricted to explicitly allowed source IPs
- mDNS (Avahi) hardened: user-service publishing blocked, no
  HINFO/workstation publishing

### Secrets Protection

| Secret                  | Protection                                                                                                           |
|-------------------------|----------------------------------------------------------------------------------------------------------------------|
| Unseal keys             | age-encrypted, TPM2-bound via `systemd-creds`                                                                        |
| Root token              | age-encrypted + passphrase backup (`.age.pass`)                                                                      |
| AppRole secret_id       | age-encrypted, same TPM2 binding. `secret_id_num_uses: 0` / `secret_id_ttl: 0` -- known mitigated config (see below) |
| TLS private key         | SELinux `vault_conf_t`, immutable attr, auditd watch                                                                 |
| Vault Agent token       | `/opt/vault/agent-run/` (0700), `tmpfiles.d` purge on boot                                                           |
| GRUB password hash      | Stored in Vault KV, fetched at deploy time                                                                           |
| vault-ssh-helper config | `/etc/vault-ssh-helper.d/config.hcl`, mode 0640, `vault_conf_t` SELinux context                                      |
| SSH CA public key       | `/etc/ssh/trusted-user-ca-keys.pem`, deployed from Vault `ssh-ca/config/ca`                                          |
| TLS client cert         | TPM2-bound P-384 via PKCS#11; registered in Chrome and Firefox NSS databases                                         |
| Ansible Vault           | `vault.yml` encrypted with `ansible-vault`                                                                           |

### AppRole secret_id Tradeoff

The AppRole `secret_id` is configured with `secret_id_num_uses: 0`
(unlimited) and `secret_id_ttl: 0` (no expiry). This is weaker than
HashiCorp's recommended posture of single-use, short-TTL secret IDs.
The configuration is mitigated by:

- TPM2-bound ciphertext protects the secret_id at rest
- Short-lived derived tokens limit blast radius
- Least-privilege policies (`vault-agent-tls` and `vault-agent-auth`)
  scope what the token can access
- The secret_id is consumed/deleted after first successful auth and
  re-provisioned on each vault-agent restart

Future improvement: extend `vault-agent-secret.service` to call
Vault's API for a fresh `secret_id` on each run.

### Corrected Security Gaps

**P-384 Root/Intermediate CA (fixed in 0.2.0):** Root CA and
Intermediate CA were silently stuck at P-256 because the `key_bits`
parameter was missing from `pki/root/generate/internal` and
`pki_int/intermediate/generate/internal` API calls. Vault defaults to
P-256 when `key_bits` is omitted for EC key types. The full PKI chain
is now consistent at P-384 (CNSA 2.0): Root CA, Intermediate CA, and
all leaf certificates (vault-server, nginx-gateway, client-auth).

**SSH OTP non-functionality (fixed in 0.2.0):** The SSH OTP feature
was documented and advertised but was completely non-functional due to
a 4-layer stacked bug: orphaned PAM file never wired into sshd, log
file DAC preventing pre-auth worker writes, wrong SELinux domain
(`sshd_t` vs Fedora 44's `sshd_session_t`), and a hidden
`dontaudit`'d `open` permission requiring `semodule -DB` to diagnose.
