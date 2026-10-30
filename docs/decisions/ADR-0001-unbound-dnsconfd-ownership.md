# ADR-0001: Unbound/dnsconfd Configuration Ownership Split

## Status

Accepted

## Context

This project runs two systems that configure the same Unbound instance:

- **dnsconfd** -- the RHEL-standard NetworkManager-to-Unbound integration
  daemon, shipped as a Fedora RPM
- **dns role** -- our Ansible role that deploys security, performance, and
  privacy hardening for Unbound

Without a clear ownership boundary, both systems can write conflicting
values for the same Unbound directives. Observed conflicts included
`tls-cert-bundle` (set by both our template and dnsconfd's
`certification_authority`) and `module-config` (dnsconfd includes
`ipsecmod` by default, which requires libreswan -- not installed here).

## Decision

Split configuration ownership as follows:

**dnsconfd owns:**

- DoT upstream servers (`static_servers` in `dnsconfd.conf`)
- `resolv.conf` management (symlink with correct `net_conf_t` SELinux
  context)
- `tls-cert-bundle` (pushed into Unbound runtime config via
  `certification_authority`)

**dns role owns:**

- `unbound.conf` via the `unbound.conf.j2` template: security directives
  (`hide-identity`, `harden-*`, DNSSEC), performance tuning (cache sizes,
  prefetch, threading), and privacy controls (`qname-minimisation`,
  `aggressive-nsec`)
- Site-local overrides in `/etc/unbound/conf.d/`: `zz-module-override.conf`
  (removes `ipsecmod`, adds `respip` for RPZ), blocklist/RPZ
  configurations
- RPZ zones are configured directly in Unbound `conf.d`, not through
  dnsconfd (see [ADR-0004](ADR-0004-rpz-via-unbound-native-not-dnsconfd.md))

**Neither system touches the other's directives.** The `tls-cert-bundle`
directive was removed from `unbound.conf.j2` to eliminate the overlap.

## Consequences

- **Positive:** No directive conflicts between dnsconfd and the dns role.
  Each system can be updated independently.
- **Positive:** dnsconfd's `certification_authority` handles the TLS cert
  bundle for both DoT upstream validation and any Unbound-native HTTPS
  operations (e.g., RPZ `url:` fetch), providing a single source of truth
  for certificate trust.
- **Positive:** The `zz-` prefix convention for conf.d overrides ensures
  site-local policy loads last, cleanly overriding dnsconfd defaults.
- **Negative:** Operators must understand which system owns which
  directives. This ADR and `docs/ARCHITECTURE.md` serve as the reference.
- **Negative:** Future dnsconfd updates could introduce new directive
  overlaps that require review.
