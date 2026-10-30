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

A future improvement (tracked in
[KNOWN_ISSUES.md](KNOWN_ISSUES.md) backlog under "break-glass cert
auto-renewal") would extend Vault Agent's `template` stanza to
pre-render break-glass certificates automatically, reducing the manual
burden of this rotation procedure.
