# ADR-0004: RPZ via Unbound-Native Config, Not dnsconfd

## Status

Accepted

## Context

Response Policy Zones (RPZ) provide DNS-level threat blocking by
rewriting query responses based on policy zone data. This project
evaluated two approaches for RPZ integration:

1. **dnsconfd's native `rpz:` directive** -- configured in
   `dnsconfd.conf`
2. **Unbound's native `rpz:` block** -- configured directly in
   Unbound's `conf.d/`

Investigation of dnsconfd's `rpz:` schema (via `dnsconfd.conf(5)`)
revealed that it only supports these keys:

- `name` -- zone name
- `master` -- IP address of an AXFR/IXFR zone transfer primary
- `zonefile` -- path to a local zone file

Critically, **dnsconfd has no `url:` key**. Unbound 1.13.2+ supports
`url:` for HTTP(S)-based RPZ zone fetching, which is the mechanism
used by feed providers such as oisd. There is no way to configure
HTTP(S)-based RPZ through dnsconfd.

## Decision

Configure RPZ **directly in Unbound's `conf.d/` directory**, bypassing
dnsconfd for this specific feature.

The RPZ configuration is deployed as a conf.d drop-in (e.g.,
`zz-rpz-oisd.conf`) containing an Unbound-native `rpz:` block with
both `url:` (for HTTP(S) fetch) and `zonefile:` (for boot resilience):

```yaml
rpz:
    name: "oisdsmall"
    url: "https://small.oisd.nl/rpz"
    zonefile: "/var/lib/unbound/oisdsmall.rpz.zone"
    rpz-action-override: nxdomain
    rpz-log: yes
    rpz-log-name: "oisd"
```

The `zonefile:` directive ensures Unbound loads the cached local copy
at startup (instant, no network dependency), fetching from the URL
only when the SOA refresh timer fires. This provides boot resilience
when the remote URL is unreachable.

The `respip` module must be present in `module-config` for RPZ to
function (see [KNOWN_ISSUES.md](../KNOWN_ISSUES.md), entry 7).

The commented RPZ placeholder in `dnsconfd.conf.j2` should be removed
and replaced with a reference to this ADR.

## Consequences

- **Positive:** Enables HTTP(S)-based RPZ feeds (oisd, abuse.ch, etc.)
  that are not possible through dnsconfd's limited `rpz:` schema.
- **Positive:** `zonefile:` provides boot resilience -- Unbound starts
  with cached RPZ data even when the feed URL is unreachable.
- **Positive:** Uses standard Unbound conf.d patterns already
  established for other site-local overrides (e.g.,
  `zz-module-override.conf`).
- **Positive:** dnsconfd remains the owner of DoT upstreams,
  `resolv.conf`, and TLS trust (see
  [ADR-0001](ADR-0001-unbound-dnsconfd-ownership.md)). The ownership
  boundary is preserved.
- **Negative:** RPZ configuration lives outside dnsconfd's management,
  so dnsconfd has no visibility into RPZ zones. Any future dnsconfd
  improvements to RPZ support would require revisiting this decision.
- **Negative:** Requires an additional SELinux boolean
  (`unbound_outbound_rpz_fetch`) to allow Unbound's outbound HTTPS
  connection for zone fetching.
