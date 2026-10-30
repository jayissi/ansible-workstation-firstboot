# ADR-0003: Certificate Rotation via systemd Path Units

## Status

Accepted

## Context

Vault Agent automatically renews TLS certificates for both Vault
itself and the Nginx reverse proxy. When a certificate is renewed,
the consuming service must reload to pick up the new cert. Three
approaches were evaluated:

1. **Cron job** -- poll at fixed intervals, reload if cert changed
2. **systemd timer + inotifywait** -- timer triggers a script that
   uses `inotifywait` to watch for file changes, then reloads
3. **systemd path unit (`PathModified`)** -- kernel inotify watch
   managed natively by systemd, triggers a oneshot reload service

Requirements:

- React to cert writes promptly (within seconds, not minutes)
- No external dependencies beyond systemd
- No polling overhead or busy-wait loops
- Clean integration with SELinux confinement (`init_t` must be able
  to read the watched path)
- Reliable across reboots without manual intervention

## Decision

Use **systemd path units** with `PathModified` for certificate
rotation:

- `vault-cert-reload.path` watches
  `/etc/vault.d/certs/server-chain.crt` and triggers
  `vault-cert-reload.service` (`systemctl reload vault`)
- `nginx-cert-reload.path` watches the proxy TLS certificate and
  triggers `nginx-cert-reload.service` (`systemctl reload nginx`)

The path units are enabled at boot via `WantedBy=multi-user.target`.

The SELinux policy grants `init_t` read access to `vault_conf_t`
files and directories, allowing systemd to watch the cert path
without AVC denials.

## Consequences

- **Positive:** Zero-latency reaction to cert writes -- systemd's
  inotify watch triggers the reload service immediately when Vault
  Agent writes a new certificate.
- **Positive:** No external dependencies. `PathModified` is built
  into systemd; no need for `inotifywait`, `incron`, or cron.
- **Positive:** No polling overhead. The kernel inotify mechanism is
  event-driven, not poll-based.
- **Positive:** Clean lifecycle management. Path units are enabled/
  disabled via `systemctl`, visible in `systemctl list-units`, and
  journaled like any other unit.
- **Positive:** Survives reboot automatically via `WantedBy`.
- **Negative:** Requires SELinux policy grant for `init_t` to read
  `vault_conf_t` -- a narrow, documented exception
  (see `vault.te`).
- **Negative:** `PathModified` reacts to any write to the watched
  file, including idempotent writes of the same content. In practice,
  Vault Agent only writes when the cert actually changes, so spurious
  reloads are rare.
