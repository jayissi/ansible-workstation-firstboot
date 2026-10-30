# ADR-0005: Vault SSH Secrets Engine — OTP Primary + Ed25519 CA Break-Glass

## Status

Accepted

## Context

The hardened workstation needs a dynamic SSH credential system to
replace (and eventually retire) the pre-existing static SSH key. The
project already runs HashiCorp Vault CE with auto-unseal (age+TPM2),
an internal PKI engine, and Vault Agent for automated certificate
rotation. Two Vault SSH secrets engine modes are available:

1. **OTP (One-Time Password)** — Vault generates a single-use password;
   `vault-ssh-helper` on the target validates it against Vault's API
   via PAM (`pam_exec.so`). The OTP is consumed on use and never
   persisted.
2. **Signed Certificate (CA)** — Vault signs the user's SSH public key
   with its internal CA. The target's `sshd` validates the certificate
   locally using `TrustedUserCAKeys`, with no Vault API call at
   SSH-time.

Key technical constraints discovered during planning:

- **OpenSSH does not support CA certificate chaining.** The
  `PROTOCOL.certkeys` specification is explicit: "Chained certificates
  are NOT supported." Each CA public key must be listed individually in
  `TrustedUserCAKeys`. This affects CA key rotation procedures (see
  [OPERATIONS.md](../OPERATIONS.md)).
- **Ed25519 vs. ECDSA for the CA signing key.** Ed25519 was chosen for
  consistency with the project's existing SSH host keys
  (`HostKey: /etc/ssh/ssh_host_ed25519_key`) and for its superior
  performance characteristics (smaller keys, faster signing). ECDSA
  P-521 was considered but rejected as overkill for short-lived
  certificates (24h TTL, 72h max TTL) that are validated once and
  discarded.
- **Vault auto-unseal ensures availability.** The existing age+TPM2
  auto-unseal mechanism means Vault is available immediately after
  boot, making OTP validation reliable for daily use without manual
  intervention.

### Alternatives Considered

| Option                      | Pros                                                  | Cons                                                                                       |
|-----------------------------|-------------------------------------------------------|--------------------------------------------------------------------------------------------|
| OTP only                    | Zero persistence, per-session credentials, simple     | No fallback if Vault is unreachable at SSH-time                                            |
| CA signed certs only        | sshd validates locally, Vault-independent at SSH-time | Certificates persist on disk until expiry; no per-session guarantee                        |
| Static SSH key (status quo) | Simple, proven                                        | Permanent credential, no rotation, no audit trail                                          |
| FIDO2/U2F (`pam_u2f`)       | Hardware-bound, phishing-resistant                    | Requires physical token; placeholder added (`auth_pam_u2f_enabled: false`) for future work |

## Decision

Deploy **both** Vault SSH secrets engine modes as complementary layers:

- **OTP (primary, daily use)** — mounted at `ssh-otp/`, role `daily`.
  Zero-persistence per-session credentials. The admin's daily workflow
  is a single command: `vault-ssh-target jayissi@workstation`.
  Rate-limited to 5 requests per 60 seconds on the
  `ssh-otp/creds/daily` path.
- **Ed25519 signed certificates (break-glass)** — mounted at `ssh-ca/`,
  role `breakglass`. Short-lived certificates (24h default TTL, 72h
  max TTL) validated locally by sshd. Used when Vault is degraded and
  OTP validation cannot complete on the target — the certificate was
  obtained from Vault before the degradation, and sshd validates it
  independently.

Both credential types are issued through the SSH credential gateway
(see [ADR-0006](ADR-0006-ssh-credential-gateway.md)), which exposes
only the `ssh-otp/creds/` and `ssh-ca/sign/` paths to the bastion.

The existing static SSH key is **not removed** in this plan. Three
authentication methods coexist until the SSH credential gateway passes
its go/no-go gate (bastion successfully obtains and uses an OTP end to
end over a soak period). Static key retirement is a separate, deliberate
follow-up decision.

### Authentication flow

```text
Daily (OTP):
  bastion → gateway :8443 → Vault ssh-otp/creds/daily → OTP issued
  bastion → sshd :22 → pam_exec → vault-ssh-helper → Vault validates OTP
  → session established

Break-glass (CA cert):
  bastion → gateway :8443 → Vault ssh-ca/sign/breakglass → signed cert issued
  bastion → sshd :22 → TrustedUserCAKeys validates cert locally (no Vault call)
  → session established
```

### SELinux impact

`vault-ssh-helper` runs as `sshd_t` (invoked via `pam_exec.so` during
sshd's `auth` phase, before `pam_selinux.so open` transitions to the
user context). It needs to connect to Vault's API on port 8200. This is
handled by SELinux Option A — a direct allow rule widening `sshd_t` to
connect to `vault_cluster_port_t`. Option B (dedicated
`vault_ssh_helper_t` domain transition) is tracked in the backlog as the
long-term improvement.

## Consequences

- **Positive:** OTP provides zero-persistence, per-session credentials
  with a full Vault audit trail for every SSH login.
- **Positive:** CA break-glass ensures access survives Vault
  unavailability at SSH-time, as long as the certificate was obtained
  beforehand.
- **Positive:** Ed25519 CA key is consistent with existing SSH host key
  algorithm and offers compact signatures.
- **Positive:** Rate limiting on OTP issuance prevents credential
  enumeration and abuse.
- **Negative:** OTP validation requires Vault to be reachable from the
  target at SSH-time. Auto-unseal mitigates this but does not eliminate
  it (Vault process crash, etc.).
- **Negative:** CA key rotation requires a manual overlap-window
  procedure because OpenSSH does not support chained certificates.
  Documented in [OPERATIONS.md](../OPERATIONS.md).
- **Negative:** Two SSH engine mounts increase Vault configuration
  surface area. Mitigated by automation (Ansible manages both) and
  the narrowly-scoped `ssh-otp-user` policy.
