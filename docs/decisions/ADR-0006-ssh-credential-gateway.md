# ADR-0006: Narrowly-Scoped SSH Credential Gateway

## Status

Accepted

## Context

Vault's API is loopback-only through **every** path that exists today.
The direct listener binds to `127.0.0.1:8200` (in `vault.hcl`), and
the existing Nginx reverse proxy binds to `127.0.0.1:443` (in
`proxy/defaults/main.yml`). There is no firewall rule for port 443.

The bastion host has **zero network path** to Vault's API. Since
`vault ssh -mode=otp` and `vault ssh -mode=ca` both require a network
call to Vault's API as their first step (request the credential before
SSH even begins), running those commands from the bastion has nowhere
to go. This is a hard architectural gap — without fixing it, the Vault
SSH secrets engine (see [ADR-0005](ADR-0005-vault-ssh-otp-ca.md)) is
unreachable from the bastion and retiring the static SSH key would lock
the bastion out entirely.

### Alternatives Considered

| Option                                          | Pros                                                              | Cons                                                                                   |
|-------------------------------------------------|-------------------------------------------------------------------|----------------------------------------------------------------------------------------|
| Widen existing Nginx proxy to `0.0.0.0:443`     | Minimal config change                                             | Exposes Vault UI, KV, PKI, sys/ — entire API surface to the network                    |
| Bind Vault itself to `0.0.0.0:8200`             | No proxy needed                                                   | Exposes raw Vault API including all admin endpoints; violates the loopback-only design |
| New narrowly-scoped gateway on a dedicated port | Only credential-issuance paths exposed; Vault stays loopback-only | Additional Nginx vhost to maintain                                                     |
| SSH ProxyJump / tunneling                       | No gateway needed                                                 | Requires the bastion to already have SSH access — circular dependency                  |

## Decision

Deploy a **second, narrowly-scoped Nginx vhost** on port 8443,
exposing exactly two write-only credential-issuance paths to the
bastion IP, while Vault itself stays bound to `127.0.0.1:8200`
**forever**.

### What the gateway exposes

| Path                 | Purpose                          | Vault Engine |
|----------------------|----------------------------------|--------------|
| `/v1/ssh-otp/creds/` | Request a one-time password      | `ssh-otp`    |
| `/v1/ssh-ca/sign/`   | Request a signed SSH certificate | `ssh-ca`     |

### What the gateway blocks

**Everything else.** The default `location /` returns HTTP 403. This
means:

- No access to Vault KV (`secret/`)
- No access to Vault PKI (`pki/`, `pki_int/`)
- No access to Vault UI
- No access to `sys/` (audit, policies, mounts, seal/unseal)
- No access to `auth/` (token, AppRole)

### Network architecture

```text
Bastion ──────►  Nginx SSH gateway (:8443)  ──────►  Vault API (127.0.0.1:8200)
                 │                                    (loopback-only, unchanged)
                 ├─ /v1/ssh-otp/creds/ → proxy_pass
                 ├─ /v1/ssh-ca/sign/   → proxy_pass
                 └─ /                  → 403
```

### Access control layers

1. **Firewall rich rule** — only `bastion_ip` can reach port 8443
2. **Nginx location blocks** — only two paths are proxied; all others
   return 403
3. **Vault policy** — the `ssh-otp-user` policy only grants
   `create`/`update` on those two paths
4. **Vault rate limit** — 5 requests per 60 seconds on
   `ssh-otp/creds/daily`
5. **TLS** — the gateway uses a PKI-issued certificate signed by the
   internal Vault Root CA; the bastion must trust the Root CA (see
   [OPERATIONS.md](../OPERATIONS.md) for enrollment)

### Configuration

The gateway is deployed by the `proxy` role as
`/etc/nginx/conf.d/vault-ssh-gateway.conf`:

- `proxy_ssh_gateway_enabled: true` (default)
- `proxy_ssh_gateway_listen_address: '0.0.0.0'` (LAN-facing, unlike
  the UI proxy)
- `proxy_ssh_gateway_port: 8443` (dedicated port, not 443, to avoid
  conflating with the UI proxy)

## Consequences

- **Positive:** Vault's loopback-only binding is permanently
  preserved. The gateway is the only network-facing component, and it
  exposes the absolute minimum API surface.
- **Positive:** Dedicated port (8443) cleanly separates the credential
  gateway from the existing UI/admin proxy (443), allowing independent
  firewall rules and monitoring.
- **Positive:** Defence in depth — four layers (firewall, Nginx
  location, Vault policy, rate limit) must all be bypassed to abuse
  the gateway.
- **Positive:** The bastion can now reach Vault's SSH credential
  endpoints, unblocking the OTP/CA authentication workflow.
- **Negative:** An additional Nginx vhost to maintain and monitor.
  Mitigated by Ansible automation and the existing cert-rotation
  infrastructure.
- **Negative:** The Root CA must be distributed to the bastion for TLS
  trust. Documented as a one-time enrollment step in
  [OPERATIONS.md](../OPERATIONS.md).
