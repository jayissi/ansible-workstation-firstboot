# ADR-0007: TLS Client Cert Auth with TPM2-Bound P-384, Vault OIDC for VaultPass

## Status

Accepted

## Context

The Vault authentication model needed reconsidering. The original
design assumed userpass+TOTP as the primary interactive auth method,
with AppRole for automated agents. However, the deployment target is a
single-admin workstation with a TPM2 chip available, which opens the
door to hardware-bound TLS client certificates as a stronger
alternative.

Two authentication needs drive this decision:

1. **Admin-to-Vault CLI/UI authentication** -- the admin needs to
   authenticate to Vault for day-to-day secret management, policy
   changes, and PKI operations.
2. **VaultPass browser extension** -- the VaultPass browser extension
   needs a Vault token to look up credentials. The token acquisition
   method must be scoped and auditable, not a direct token grab from
   the filesystem.

The workstation's TPM2 module can bind a P-384 private key via
PKCS#11, providing a physical-presence guarantee without passwords or
TOTP seeds. The Vault PKI engine already issues P-384 certificates
(CNSA 2.0) across the full chain, making client certificate issuance a
natural extension of the existing infrastructure.

### Alternatives Considered

| Option                                      | Pros                                                                                      | Cons                                                                                                                                                 |
|---------------------------------------------|-------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| Userpass + TOTP MFA fallback                | Familiar UX, software-only                                                                | Password-based auth surface; TOTP seeds are copyable (no hardware binding); TPM2 already provides physical-presence guarantee, making TOTP redundant |
| Direct VaultPass token grab from filesystem | Simple implementation                                                                     | No audit trail for token acquisition; token scope hard to limit; token lifetime uncontrolled; no client_id binding                                   |
| Vault OIDC Identity Provider for VaultPass  | Scoped, auditable, time-limited tokens; explicit client_id binding; standard browser flow | Additional Vault configuration; requires OIDC discovery endpoint availability                                                                        |

## Decision

Deploy **TLS client certificate as the PRIMARY Vault authentication
method**, with no userpass fallback, combined with **Vault as an OIDC
Identity Provider** scoped exclusively to the VaultPass browser
extension.

### TLS Client Certificate Auth

- **Key type:** ECDSA P-384 via PKCS#11 (TPM2-bound)
- **Auth method:** Vault `cert` auth backend with client certificate
  verification against the internal Intermediate CA
- **Fallback:** None. No userpass method is configured. If the TPM2
  hardware is unavailable, the admin must use the break-glass SSH
  certificate path (see [ADR-0005](ADR-0005-vault-ssh-otp-ca.md))
  to reach the host, then authenticate locally
- **Browser registration:** The client certificate is registered in
  both Chrome and Firefox NSS databases via `certutil` so that
  browser-based Vault UI access uses the same hardware-bound
  credential

### Vault OIDC Identity Provider

- **Scoped client:** `allowed_client_ids` set to `vaultpass` only
  (not wildcard) -- no other OIDC client can obtain tokens
- **Signing key:** ES384 (matching the P-384 PKI chain) with 6-hour
  automatic rotation
- **Issuer:** Explicitly configured (not auto-detected) to match the
  `https://vault.local` URL
- **Custom scopes:** None -- default OIDC claims only, minimizing
  information disclosure
- **Token lifetime:** Time-limited by the OIDC provider configuration;
  VaultPass must re-authenticate when the token expires

### Configuration

The TLS client cert auth and OIDC provider are deployed by the `vault`
role:

- `vault_auth_cert_enabled: true`
- `vault_oidc_provider_enabled: true`
- `vault_oidc_allowed_client_ids: ['vaultpass']`
- `vault_oidc_signing_alg: ES384`
- `vault_oidc_key_rotation_period: 6h`

### Split Vault Agent Policies

To support TLS client cert auth alongside automated agent operations,
Vault Agent policies are split into two scopes:

| Policy             | Scope                                            |
|--------------------|--------------------------------------------------|
| `vault-agent-tls`  | Certificate renewal operations (PKI issue/renew) |
| `vault-agent-auth` | AppRole authentication and token management      |

This separation ensures that a compromised agent token from one scope
cannot access the other's capabilities.

## Consequences

- **Positive:** Smaller attack surface -- no password-based auth path
  exists at all. An attacker cannot brute-force, phish, or replay a
  password because there is no password to target.
- **Positive:** TPM2 hardware binding provides a physical-presence
  guarantee that is stronger than TOTP (which relies on copyable
  seeds) and cannot be exfiltrated remotely.
- **Positive:** OIDC token issuance for VaultPass is scoped,
  auditable, and time-limited. Every token acquisition generates a
  Vault audit log entry with the `vaultpass` client_id. Contrast with
  direct filesystem token grabs which leave no audit trail.
- **Positive:** Full P-384 consistency -- the client cert uses the
  same curve and CA chain as the server TLS certificates, simplifying
  the trust model.
- **Negative:** TPM2 hardware dependency for enrollment. If the TPM2
  module fails, the admin loses the primary auth path and must use
  break-glass procedures.
- **Negative:** PKCS#11 registration required in both Chrome and
  Firefox NSS databases. This is a one-time setup step per browser
  but adds operational complexity. The procedure is documented in
  [OPERATIONS.md](../OPERATIONS.md).
- **Negative:** No password fallback means that remote support
  scenarios (where only a password can be transmitted) are not
  possible. Mitigated by the single-admin, physical-access deployment
  model.
