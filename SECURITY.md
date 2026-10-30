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

| Component                  | Purpose                                                                                                                                                            |
|----------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **SELinux** (enforcing)    | Mandatory access control. Admin mapped to `staff_u`; system users to `unconfined_u` (GUI-safe). Custom policy modules for `vault_t` and DNS services.              |
| **fapolicyd**              | Application allowlisting. SHA-256 integrity verification; only RPM-installed and explicitly trusted binaries execute.                                              |
| **AIDE**                   | File integrity monitoring. Database initialized *last* after all hardening is complete, capturing the fully hardened baseline. Daily checks via systemd timer.     |
| **USBGuard**               | USB device allowlisting. Blocks unauthorized USB devices at the kernel level.                                                                                      |
| **HashiCorp Vault CE**     | Secrets backbone. ECDSA P-256 TLS via internal PKI engine; auto-rotating certificates; age+TPM2 encrypted unseal keys.                                             |
| **Auth**                   | Authselect + PAM hardening (faillock, pwquality, pwhistory). vault-ssh-helper OTP validation via `pam_exec`. Custom SELinux policy for sshd-to-Vault connectivity. |
| **SSH Credential Gateway** | Nginx vhost (:8443) exposing only `/v1/ssh-otp/creds/` and `/v1/ssh-ca/sign/` to the bastion. All other paths return 403.                                          |
| **Auditd**                 | Kernel audit framework. 50 CIS/NIST/STIG-aligned syscall rules covering file access, privilege escalation, and authentication events.                              |

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
  `AllowUsers` restriction, security banner
- DNS: DNSSEC + DNS-over-TLS, outbound plaintext DNS (port 53) blocked
- Firewall: zone target `DROP`, service-specific allow rules only
- Crypto policies: RHEL `FUTURE` profile via `linux-system-roles.crypto_policies`
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

| Secret                  | Protection                                                                      |
|-------------------------|---------------------------------------------------------------------------------|
| Unseal keys             | age-encrypted, TPM2-bound via `systemd-creds`                                   |
| Root token              | age-encrypted + passphrase backup (`.age.pass`)                                 |
| AppRole secret_id       | age-encrypted, same TPM2 binding                                                |
| TLS private key         | SELinux `vault_conf_t`, immutable attr, auditd watch                            |
| Vault Agent token       | `/opt/vault/agent-run/` (0700), `tmpfiles.d` purge on boot                      |
| GRUB password hash      | Stored in Vault KV, fetched at deploy time                                      |
| vault-ssh-helper config | `/etc/vault-ssh-helper.d/config.hcl`, mode 0640, `vault_conf_t` SELinux context |
| SSH CA public key       | `/etc/ssh/trusted-user-ca-keys.pem`, deployed from Vault `ssh-ca/config/ca`     |
| Ansible Vault           | `vault.yml` encrypted with `ansible-vault`                                      |
