# ADR-0002: Vault SELinux Policy Design

## Status

Accepted

## Context

HashiCorp Vault CE runs as a system daemon on a SELinux-enforcing
Fedora workstation. Vault does not ship an upstream SELinux policy, so
a custom policy module is required to confine the `vault` process.

Key requirements:

- Vault must read its configuration and TLS certificates in `/etc/vault.d/`
- Vault must read/write its Raft storage in `/opt/vault/data/`
- Vault must bind to ports 8200 (API) and 8201 (cluster)
- Vault Agent must write renewed certificates to both `/etc/vault.d/certs/`
  and `/etc/nginx/certs/` (proxy leaf cert)
- Vault Agent spawns shell commands (`/usr/bin/systemctl reload`)
  as template hooks
- Outbound DNS (UDP) and HTTP (TCP) access are sometimes needed but
  should not be granted unconditionally

Design considerations:

- Multiple small modules vs. one consolidated module
- Static allow rules vs. `gen_tunable` booleans for optional access

## Decision

Use a **single `vault.te` policy module** for the entire `vault_t`
domain, with `gen_tunable` booleans for optional network access:

- `vault_outbound_udp_dns` (default: `false`) -- allows Vault to make
  outbound UDP DNS queries
- `vault_outbound_http` (default: `false`) -- allows Vault to connect
  to external HTTP(S) servers and read system CA certificates

Custom file context types:

| Type                   | Path              | Purpose                                   |
|------------------------|-------------------|-------------------------------------------|
| `vault_exec_t`         | `/usr/bin/vault`  | Binary entrypoint                         |
| `vault_conf_t`         | `/etc/vault.d/`   | Configuration and TLS certificates        |
| `vault_sys_content_t`  | `/opt/vault/`     | Raft data, agent runtime, SELinux sources |
| `vault_log_t`          | `/var/log/vault/` | Audit and operational logs                |
| `vault_cluster_port_t` | TCP 8201          | Cluster communication port                |

The module grants Vault Agent write access to `httpd_config_t`
(`/etc/nginx/certs/`) for proxy certificate rotation, with the
Nginx reload triggered by a systemd path unit (see
[ADR-0003](ADR-0003-cert-rotation-path-units.md)).

## Consequences

- **Positive:** Single module simplifies deployment -- one `semodule -i`
  operation, one version to track.
- **Positive:** `gen_tunable` booleans follow the principle of least
  privilege. Network access is off by default and enabled only in
  inventory when needed (e.g., `vault_outbound_http` for OCSP or
  external PKI operations).
- **Positive:** Booleans are toggled at runtime via `setsebool` without
  recompiling the policy module.
- **Negative:** A single module means all `vault_t` rules are coupled.
  A change to any rule requires reloading the entire module. For a
  single-host workstation deployment, this trade-off is acceptable.
- **Negative:** Future Vault features may require new allow rules. Each
  must be added to `vault.te` and the module version bumped.
