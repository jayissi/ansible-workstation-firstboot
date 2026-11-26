# ADR-0008: `.internal` Namespace for Project Service Hostnames

## Status

Accepted (2026-11-25). Supersedes the `.local` hostnames used since the
initial Nginx gateway (ADR-0006, ADR-0007).

## Context

The project's own services used the `.local` TLD: `vault.local`,
`status.vault.local` and `vault-ssh-gateway.local`. RFC 6762 reserves
`.local` for multicast DNS (Avahi / Bonjour), which this workstation also
runs. Two independent architecture reviews (KNOWN_ISSUES Priority 14)
flagged the overlap:

- The nsswitch `hosts:` line `files mdns_minimal [NOTFOUND=return] ...`
  could end resolution at mDNS before Unbound was consulted. Only the
  `/etc/hosts` entry for `vault.local` masked this.
- Unbound needed a `local-zone: "local." nodefault` workaround.
- The names were hard-coded in 23 places (Nginx `server_name`, CRL URLs,
  browser policies, tests). Two separate variables
  (`vault_local_hostname`, `proxy_server_name`) held the same value and
  could drift, which would break `proxy_ssl_name` (every request → 502).

### Alternatives Considered

| Option                              | Pros                                                          | Cons                                                                     |
|-------------------------------------|---------------------------------------------------------------|--------------------------------------------------------------------------|
| Keep `.local`                       | No change                                                     | Conflicts with mDNS (RFC 6762); fragile resolution order                 |
| `.home.arpa` (RFC 8375)             | IETF-reserved for home networks                               | Intended for residential networks; long names                            |
| `.internal`                         | ICANN-reserved for private use (2024); short; never delegated | Requires a one-time rename and certificate reissue                       |
| A real subdomain of an owned domain | Globally unique                                               | Needs a registered domain; leaks naming into public DNS if misconfigured |

## Decision

Use `.internal`:

| Old name                  | New name                     |
|---------------------------|------------------------------|
| `vault.local`             | `vault.internal`             |
| `status.vault.local`      | `status.vault.internal`      |
| `vault-ssh-gateway.local` | `vault-ssh-gateway.internal` |

All three are defined **once**, in `inventory/group_vars/all/main.yml`
(`vault_local_hostname`, `vault_status_hostname`,
`vault_ssh_gateway_hostname`). Everything else derives from them:
`proxy_server_name`, Nginx `server_name`/`proxy_ssl_name`, certificate
SANs, Unbound `local-data`, `/etc/hosts`, the CRL refresh script (now a
template), browser bookmarks and certificate auto-select patterns, the
OIDC redirect URI, and `tests/security-test.sh` defaults.

`.local` remains in use **only** for mDNS (Avahi `domain-name=local`,
nsswitch `mdns_minimal`). Unbound's `private-domain` is now `internal`,
and the `local-zone: "local." nodefault` workaround was removed.

## Consequences

- **Positive:** No overlap with mDNS; one source of truth; no drift
  between Nginx and certificate names.
- **Positive:** Combined with nsswitch `[NOTFOUND=continue]`
  (KNOWN_ISSUES P21), name resolution no longer depends on `/etc/hosts`.
- **Negative:** Existing hosts need certificates reissued with the new
  SANs. Fresh deploys get them automatically; the in-place procedure is
  in [OPERATIONS.md](../OPERATIONS.md) ("Hostname Migration").
- **Negative:** Each user must update the Vault URL saved in the
  VaultPass extension to `https://vault.internal`.
- A cleanup task removes the legacy `127.0.0.1 vault.local` line from
  `/etc/hosts` on upgraded hosts.
