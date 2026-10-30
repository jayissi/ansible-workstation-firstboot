# Operations Guide

## Bastion Enrollment for SSH OTP

This section documents how to enroll a bastion host so it can obtain
Vault-issued OTP (and break-glass CA-signed) SSH credentials through
the SSH credential gateway, then use them to log in to the hardened
workstation.

### Architecture

```text
 Bastion                        Target workstation
 ───────                        ──────────────────
   │                                │
   │  1. vault ssh -mode=otp        │
   │     (requests OTP via          │
   │      HTTPS :8443 gateway)      │
   ├──────────────────────────────►  │  Nginx SSH gateway
   │                                │  → Vault 127.0.0.1:8200
   │  2. SSH to port 22 with OTP    │
   ├──────────────────────────────►  │  sshd + pam_exec
   │                                │  → vault-ssh-helper validates
   │  3. Session established        │
   │◄─────────────────────────────► │
```

The SSH credential gateway (Nginx vhost on port 8443) exposes **only**
two Vault API paths:

- `/v1/ssh-otp/creds/` — request a one-time password
- `/v1/ssh-ca/sign/` — request a signed SSH certificate (break-glass)

All other paths return HTTP 403. Vault itself remains bound to
`127.0.0.1:8200` and is never directly reachable from the network.

### Prerequisites

Install the following packages on the **bastion** (not the target):

```bash
# HashiCorp Vault CLI (from the HashiCorp repository)
# and sshpass (feeds the OTP to SSH's password prompt automatically)
sudo dnf install vault sshpass
```

### Root CA Distribution

The gateway's TLS certificate is signed by the target's internal Vault
PKI Root CA, which the bastion does not trust by default. Copy the Root
CA certificate from the target to the bastion's system trust store:

```bash
# From the bastion, copy the Root CA from the target
scp jayissi@workstation:/etc/pki/ca-trust/source/anchors/vault-root-ca.crt /tmp/

# Install and activate the trust anchor
sudo cp /tmp/vault-root-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

Alternatively, if Ansible manages the bastion, use a `fetch` +
`copy` + `update-ca-trust` task sequence.

### Daily Usage — OTP Login

The `vault-ssh-target` wrapper script is deployed to
`/usr/local/bin/vault-ssh-target` on the target. Copy it to the bastion
or use it directly:

```bash
# One-command OTP login (requests OTP, then SSH's in automatically)
vault-ssh-target jayissi@workstation
```

The wrapper sets `VAULT_ADDR` to `https://<target-ip>:8443` and
`VAULT_CACERT` to the system CA bundle, then runs:

```bash
vault ssh -mode=otp -role=daily -mount-point=ssh-otp <user>@<host>
```

Both `VAULT_ADDR` and `VAULT_CACERT` can be overridden via environment
variables if your setup differs.

### Break-Glass — CA-Signed Certificate Login

If Vault is degraded and OTP validation cannot complete on the target,
use a CA-signed SSH certificate instead. The certificate is validated
locally by sshd using `TrustedUserCAKeys` and does not require Vault to
be reachable at SSH-time (only at credential-request time):

```bash
vault ssh -mode=ca -role=breakglass -mount-point=ssh-ca jayissi@workstation
```

This uses the same SSH credential gateway (port 8443) to request a
short-lived Ed25519-signed certificate, then SSH's in using that
certificate for authentication.

### Go / No-Go Gate

Before any static SSH key retirement discussion proceeds, confirm that
the following works end to end **from the bastion**:

```bash
vault-ssh-target jayissi@workstation
```

If this command successfully retrieves an OTP through the gateway and
completes an SSH login, the credential gateway is proven functional.
If it fails, investigate the gateway's Nginx `location` scoping,
firewall rules, or bastion enrollment steps before proceeding.

---

## SSH CA Key Rotation

> **Note:** Individual break-glass SSH certificates now auto-renew
> via Vault Agent's `template` stanza (`breakglass-ssh-cert.tpl`).
> This runbook is for rotating the **CA signing key itself**, not for
> renewing individual certificates.

This runbook documents the procedure for rotating the Vault SSH CA
signing key used by the break-glass certificate authentication path.

### Background

- The SSH CA signing key is an Ed25519 key managed by Vault's `ssh-ca`
  secrets engine (see
  [ADR-0005](decisions/ADR-0005-vault-ssh-otp-ca.md)).
- **OpenSSH does not support CA certificate chaining** — the
  `PROTOCOL.certkeys` specification is explicit: "Chained certificates
  are NOT supported." Each CA public key must be listed individually
  in `TrustedUserCAKeys`.
- Certificates signed by the old CA remain valid until they expire (up
  to `vault_ssh_ca_max_ttl`, currently 72h).
- OTP authentication is **not affected** by CA key rotation. OTP
  validation uses a completely separate code path (vault-ssh-helper →
  Vault API). Only break-glass certificate authentication depends on
  the CA key.

### Prerequisites

- Root token or admin token with `sys/mounts/ssh-ca` capabilities
- SSH access to the target (via OTP or existing static key)
- The current `vault_ssh_ca_max_ttl` value (default: `72h`)

### Procedure

#### Step 1 — Record the current CA public key

```bash
# Fetch the current CA public key from Vault
vault read -field=public_key ssh-ca/config/ca > /tmp/old-ca-pubkey.pem

# Verify it matches what sshd currently trusts
diff /tmp/old-ca-pubkey.pem /etc/ssh/trusted-user-ca-keys.pem
```

#### Step 2 — Generate a new CA signing key

```bash
# Delete and regenerate the CA key pair inside Vault
vault delete ssh-ca/config/ca
vault write ssh-ca/config/ca generate_signing_key=true key_type=ed25519

# Fetch the new CA public key
vault read -field=public_key ssh-ca/config/ca > /tmp/new-ca-pubkey.pem
```

#### Step 3 — Trust both old and new CA keys (overlap window)

Concatenate both public keys into `TrustedUserCAKeys` so sshd accepts
certificates signed by either CA during the overlap window:

```bash
# Concatenate old + new CA public keys
cat /tmp/old-ca-pubkey.pem /tmp/new-ca-pubkey.pem > /etc/ssh/trusted-user-ca-keys.pem

# Verify sshd config is valid
sshd -t

# Reload sshd to pick up the new trust file
systemctl reload sshd
```

Alternatively, re-run the Ansible playbook with the vault and sshd
tags — the `ssh_engine.yml` tasks will fetch the new public key
automatically. Manually append the old key to the deployed file before
the overlap window expires.

#### Step 4 — Wait for the overlap window to expire

The overlap window must be **at least as long as `vault_ssh_ca_max_ttl`**
(currently 72h). This ensures all certificates signed by the old CA
have expired before the old key is removed from trust.

```bash
# Check vault_ssh_ca_max_ttl
vault read ssh-ca/roles/breakglass | grep max_ttl
```

**Do not proceed to Step 5 until the full overlap window has elapsed.**

#### Step 5 — Remove the old CA key

Once all outstanding certificates signed by the old CA have expired:

```bash
# Deploy only the new CA public key
cp /tmp/new-ca-pubkey.pem /etc/ssh/trusted-user-ca-keys.pem

# Validate and reload
sshd -t
systemctl reload sshd
```

#### Step 6 — Verify

```bash
# Request a new break-glass certificate signed by the new CA
vault ssh -mode=ca -role=breakglass -mount-point=ssh-ca jayissi@workstation

# Confirm the session establishes successfully
```

### Rollback

If the new CA key causes issues, restore the old CA public key:

```bash
cp /tmp/old-ca-pubkey.pem /etc/ssh/trusted-user-ca-keys.pem
sshd -t && systemctl reload sshd
```

Then reconfigure Vault's `ssh-ca` engine with the old key (requires
the old private key, which Vault does not export — if unavailable,
keep the new key and extend the overlap window instead).

### Automation Note

Break-glass SSH certificates now auto-renew via Vault Agent's
`template` stanza (the `breakglass-ssh-cert.tpl` template signs the
admin's public key via `ssh-ca/sign/breakglass` and writes the signed
cert to `/etc/vault.d/certs/breakglass-cert.pub`). **This runbook is
for rotating the SSH CA signing key itself**, not for renewing
individual certificates.

---

## TPM2 Client Certificate Enrollment

This section documents the `vault-enroll-client-cert` procedure for
registering a TLS client certificate in the browser's PKCS#11 store
via TPM2.

### Prerequisites

- Vault Agent is running and the `client-auth-combined.tpl` template
  has produced a valid client certificate
- `p11-kit`, `gnutls-utils`, and `nss-tools` packages are installed
- TPM2 PKCS#11 module is available at the configured handle
  (`vault_client_cert_tpm2_handle`, default `0x81000001`)

### Procedure

#### Step 1 — Verify the client certificate exists

```bash
# Check that Vault Agent has rendered the client cert
ls -la /opt/vault/agent-run/client-auth-combined.tmp

# Verify the cert was split correctly
openssl x509 -in /path/to/client-cert.pem -noout -subject -issuer
```

#### Step 2 — Register PKCS#11 module in browser NSS databases

The `modutil` command registers the TPM2 PKCS#11 module in each
browser's NSS database:

```bash
# Chrome NSS database
modutil -add "TPM2 PKCS#11" \
  -libfile /usr/lib64/pkcs11/libtpm2_pkcs11.so \
  -dbdir sql:$HOME/.pki/nssdb \
  -force

# Firefox NSS database (profile path varies)
FIREFOX_PROFILE=$(find ~/.mozilla/firefox -maxdepth 1 -name '*.default-release' -type d)
modutil -add "TPM2 PKCS#11" \
  -libfile /usr/lib64/pkcs11/libtpm2_pkcs11.so \
  -dbdir sql:"$FIREFOX_PROFILE" \
  -force
```

#### Step 3 — Verify enrollment

```bash
# List registered modules
modutil -list -dbdir sql:$HOME/.pki/nssdb

# Test TLS client auth against Vault
curl --cert /path/to/client-cert.pem \
     --key /path/to/client-key.pem \
     --cacert /etc/pki/ca-trust/source/anchors/vault-root-ca.crt \
     https://vault.local/v1/auth/cert/login
```

---

## VaultPass Setup and First Use

VaultPass is a browser extension for retrieving secrets from Vault's
KV store, authenticated via OIDC through the local Vault instance.

### Prerequisites

- Vault is running, unsealed, and accessible at `https://vault.local`
- The `vaultpass.yml` task has seeded the KV store and created the
  `vaultpass-readonly` policy
- `cert_auth.yml` has configured the OIDC provider
- Browser trust store includes the Vault Root CA

### Browser Configuration

Both Chrome and Firefox enforce a **private-browsing-only** policy for
VaultPass via enterprise managed policies. This prevents secrets from
being cached in normal browsing sessions.

### First-Use OIDC Login Flow

1. Open the VaultPass extension in the browser
2. Set the Vault address to `https://vault.local`
3. Select **OIDC** as the authentication method
4. Click **Login** — the browser opens the OIDC authorization endpoint
   at `https://vault.local`
5. Complete authentication (TLS client certificate or password)
6. VaultPass receives a short-lived token
   (`vault_vaultpass_token_ttl`, default 1h) scoped to the
   `vaultpass-readonly` policy
7. Secrets are available from the `secret/vaultPass` KV path

### Token Lifecycle

| Parameter | Default | Purpose                                  |
|-----------|---------|------------------------------------------|
| `ttl`     | 1h      | Token expires after 1 hour of inactivity |
| `max_ttl` | 24h     | Absolute token lifetime ceiling          |

Re-authentication is required after the token expires. The readonly
policy restricts access to `secret/data/vaultPass/*` (read + list
only).

---

## AIDE Baseline Re-Seal Procedure

The `aide_init` variable is gated to first-ever bootstrap only (see
[ARCHITECTURE.md](ARCHITECTURE.md) Phase 3 pre\_tasks). After
intentional system changes that should be captured in the baseline,
follow this procedure to deliberately re-initialize.

### When to Re-Baseline

- After adding or removing packages that modify system binaries
- After intentional filesystem layout changes
- After kernel or bootloader updates that alter `/boot`
- **Never** as a routine step — AIDE's value depends on a stable
  baseline that persists between deploys

### Procedure

#### Step 1 — Delete the existing baseline

```bash
sudo rm /var/lib/aide/aide.db.gz
```

#### Step 2 — Re-run the deploy

```bash
make deploy
```

The Phase 3 `pre_tasks` `stat` check will find no baseline and set
`aide_init: true`, causing `linux-system-roles.aide` to run
`aide --init` and produce a fresh baseline.

#### Step 3 — Verify the new baseline

```bash
# Confirm the baseline was created
ls -la /var/lib/aide/aide.db.gz

# Run a check to confirm no unexpected drift
sudo aide --check
```

### Security Note

Deleting the baseline is a privileged, auditable action. The daily
`aide --check` cron job (04:05) will report errors if no baseline
exists, providing visibility into any gap between deletion and
re-creation.

---

## SSH OTP Troubleshooting

### SELinux `dontaudit` Debugging Technique

When SSH OTP login fails silently (vault-ssh-helper returns an error
but `ausearch -m avc` shows no denials), the cause may be a
`dontaudit` rule hiding the real AVC. The base SELinux policy includes
`dontaudit` rules for common, harmless permission probes — but these
can mask genuine denials needed by PAM extensions.

#### Diagnostic Procedure

```bash
# Step 1: Disable ALL dontaudit rules for full AVC visibility
sudo semodule -DB

# Step 2: Reproduce the failure
# (attempt an SSH OTP login from the bastion)

# Step 3: Search for the now-visible AVCs
sudo ausearch -m avc -ts recent

# Step 4: Re-enable dontaudit rules immediately after
sudo semodule -B
```

**Critical:** `semodule -DB` recompiles the entire SELinux policy
with all `dontaudit` rules removed. This produces significant audit
noise from every process on the system. Re-enable with `semodule -B`
as soon as diagnostic data is captured.

#### What This Found

The SSH OTP fix required discovering 4 stacked layers of bugs, each
only visible after fixing the previous one:

1. **Orphaned PAM file** — vault-ssh-helper config was in a standalone
   `/etc/pam.d/vault-ssh-helper` file that sshd never references
2. **Log file DAC** — sshd's pre-auth worker runs unprivileged and
   cannot create files in `/var/log/`
3. **Wrong SELinux domain** — the PAM auth stack runs in
   `sshd_session_t` (Fedora 44), not `sshd_t`
4. **Hidden `dontaudit`'d `open` permission** — `sshd_session_t`
   needed `open` on `var_log_t` (file class), but the base policy's
   `dontaudit` rule for this exact pattern suppressed the AVC. Only
   visible after `semodule -DB`.

The `file` class requires **both** `open` AND the specific access
permission (`append`, `read`, etc.) as separate, independently-checked
permissions.

---

## P-384 CA Rotation Procedure

This runbook documents how to regenerate the Root and Intermediate CA
when the key curve needs changing (e.g., upgrading from P-256 to
P-384) on an existing deployment.

### Background

Vault's `pki/root/generate/internal` and
`pki_int/intermediate/generate/internal` endpoints require an explicit
`key_bits` parameter for EC keys. Without it, Vault silently defaults
to P-256 regardless of what leaf-issuing PKI roles specify. This was
confirmed via runtime testing: the Root and Intermediate CA were issued
at P-256 while leaf certs were correctly P-384, undermining the entire
CNSA 2.0 posture.

### Prerequisites

- Root token access (the admin-daily token cannot manage PKI mounts)
- Scheduled maintenance window — all TLS connections will be
  disrupted during re-issuance

### Procedure

#### Step 1 — Delete the existing Root CA

```bash
# Delete the root PKI mount entirely
vault secrets disable pki
```

#### Step 2 — Regenerate Root CA with correct key_bits

```bash
# Re-enable and generate with explicit P-384
vault secrets enable -path=pki pki
vault secrets tune -max-lease-ttl=87600h pki
vault write pki/root/generate/internal \
  common_name="Local Lab Infrastructure Root CA" \
  issuer_name="root-ca" \
  key_type=ec \
  key_bits=384 \
  ttl=87600h
```

#### Step 3 — Delete and regenerate Intermediate CA

```bash
# Delete the intermediate PKI mount
vault secrets disable pki_int

# Re-enable and generate CSR with explicit P-384
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=8760h pki_int
vault write pki_int/intermediate/generate/internal \
  common_name="Local Lab Infrastructure Intermediate CA" \
  issuer_name="intermediate-ca" \
  key_type=ec \
  key_bits=384
```

#### Step 4 — Sign the Intermediate and set the signed certificate

```bash
# Sign with Root CA
vault write pki/root/sign-intermediate \
  csr=@intermediate.csr \
  format=pem_bundle \
  ttl=8760h

# Set the signed certificate
vault write pki_int/intermediate/set-signed \
  certificate=@signed-intermediate.pem
```

#### Step 5 — Re-issue all leaf certificates

All 3 PKI roles must re-issue:

```bash
# Vault server cert
vault write pki_int/issue/vault-server \
  common_name="HashiCorp Vault" \
  alt_names="localhost,vault.local" \
  ip_sans="127.0.0.1"

# Nginx gateway cert
vault write pki_int/issue/nginx-gateway \
  common_name="Nginx Gateway" \
  alt_names="vault.local"

# Client auth cert
vault write pki_int/issue/client-auth \
  common_name="jayissi - VaultPass"
```

Or re-run the Ansible playbook with the `vault` and `proxy` tags to
let Vault Agent handle re-issuance automatically.

#### Step 6 — Update trust stores and restart services

```bash
# Export and install the new Root CA
vault read -field=certificate pki/cert/ca > /tmp/vault-root-ca.crt
sudo cp /tmp/vault-root-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust

# Restart services to pick up new certs
sudo systemctl restart vault vault-agent nginx
```

#### Step 7 — Verify the full chain

```bash
# Verify Root CA curve
openssl x509 -in /etc/pki/ca-trust/source/anchors/vault-root-ca.crt \
  -noout -text | grep -A2 "Public Key Algorithm"

# Verify a leaf cert's chain
openssl verify -CAfile /etc/pki/ca-trust/source/anchors/vault-root-ca.crt \
  /etc/vault.d/certs/server-chain.crt

# Confirm P-384 across all certs
for cert in /etc/vault.d/certs/server-chain.crt \
            /etc/nginx/certs/proxy-chain.crt; do
  echo "=== $cert ==="
  openssl x509 -in "$cert" -noout -text | grep "ASN1 OID:"
done
```

All certs should show `ASN1 OID: secp384r1` (P-384).
