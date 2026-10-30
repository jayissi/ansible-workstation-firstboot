# Known Issues

Troubleshooting knowledge base for the ansible-workstation-firstboot
project. Each entry documents a verified issue with symptoms, root
cause, fix, validation, and current status.

---

## DNS

### 1. Unbound chroot conflicts with absolute paths

**Symptoms:** Unbound fails to start or cannot find root-hints and
trust-anchor files. Error messages reference paths inside a chroot
that do not exist.

**Root Cause:** Unbound's default `chroot` setting rewrites absolute
paths relative to the chroot directory. The `auto-trust-anchor-file`
and `root-hints` directives use absolute paths that become invalid
inside the chroot.

**Fix:** Set `chroot: ""` (empty string) in `unbound.conf.j2`.
SELinux `unbound_t` confinement provides equivalent (and stronger)
isolation, making chroot redundant.

**Validation:** Unbound starts successfully; `unbound-control status`
shows the resolver is operational with DNSSEC validation active.

**Status:** Fixed.

---

### 2. Blocklist local-zone ordering after forward-zone context

**Symptoms:** Unbound rejects the blocklist configuration or fails to
apply local-zone entries when they appear after forward-zone
directives in the main config.

**Root Cause:** Unbound's config parser is context-sensitive.
`local-zone` directives placed after a `forward-zone` block are
parsed in the wrong context, causing syntax errors or silent
ignoring.

**Fix:** Deploy the blocklist as `50-blocklist.conf` in
`/etc/unbound/conf.d/`. The `include: /etc/unbound/conf.d/*.conf`
directive in `unbound.conf` loads conf.d files in the `server:`
context, ensuring correct parsing.

**Validation:** `unbound-checkconf` passes; blocklist domains
resolve to `0.0.0.0` as expected.

**Status:** Fixed.

---

### 3. dnsconfd forward-zone loop

**Symptoms:** After dnsconfd starts and writes its forward-zone
configuration, DNS queries loop or fail intermittently.
NetworkManager's DNS resolution may conflict.

**Root Cause:** NetworkManager holds stale DNS configuration that
conflicts with dnsconfd's Unbound management. If NM is not reloaded
after dnsconfd takes ownership, both compete for resolver control.

**Fix:** Reload NetworkManager after dnsconfd starts. The dns role's
service tasks ensure proper ordering: dnsconfd starts first, then NM
is reloaded to pick up the new resolver configuration.

**Validation:** `resolvectl status` shows dnsconfd-managed
configuration; `dig` queries resolve correctly through Unbound.

**Status:** Fixed.

---

### 4. dnsconfd ipsecmod requires libreswan hook

**Symptoms:** Unbound logs warnings about `ipsecmod` in
`module-config` but the ipsec hook binary is not found.

**Root Cause:** dnsconfd's default Unbound configuration includes
`ipsecmod` in the `module-config` directive, which requires
libreswan's `ipsec` binary as a hook. This project does not install
libreswan.

**Fix:** Deploy `zz-module-override.conf` in `/etc/unbound/conf.d/`
that overrides `module-config` to remove `ipsecmod`, setting it to
`"validator iterator"`. The `zz-` prefix ensures it loads last,
overriding any dnsconfd-generated module-config.

**Validation:** No ipsecmod warnings in Unbound logs;
`unbound-control status` shows clean module list.

**Status:** Fixed.

---

### 5. resolv.conf symlink SELinux `named_conf_t` vs `net_conf_t`

**Symptoms:** SELinux AVC denials when services attempt to read
`/etc/resolv.conf` because it has `named_conf_t` context instead of
the expected `net_conf_t`.

**Root Cause:** When Unbound or the dns role manages `resolv.conf`
directly, the symlink or file may inherit `named_conf_t` from the
Unbound config directory context. Services expect `net_conf_t` on
`resolv.conf`.

**Fix:** dnsconfd manages `resolv.conf` as part of its standard
operation, creating it with the correct `net_conf_t` SELinux context.
The dns role does not touch `resolv.conf` directly.

**Validation:** `ls -Z /etc/resolv.conf` shows `net_conf_t`;
no AVC denials related to resolver config.

**Status:** Fixed (by dnsconfd ownership; see
[ADR-0001](decisions/ADR-0001-unbound-dnsconfd-ownership.md)).

---

### 6. dnsconfd `rpz:` directive has no `url:` key

**Symptoms:** Attempting to configure RPZ via `dnsconfd.conf` with a
`url:` key for HTTP(S)-based zone fetching results in a schema
validation error or the key being silently ignored.

**Root Cause:** dnsconfd's native `rpz:` schema only supports `name`,
`master` (for AXFR/IXFR zone transfer), and `zonefile` keys. There
is no `url:` key for HTTP(S)-based RPZ zone fetching, which is an
Unbound-native feature (added in Unbound 1.13.2).

**Fix:** Configure RPZ directly in Unbound's `conf.d/` directory,
bypassing dnsconfd for this specific directive. See
[ADR-0004](decisions/ADR-0004-rpz-via-unbound-native-not-dnsconfd.md).

**Validation:** RPZ configuration accepted by `unbound-checkconf`;
dnsconfd operates normally without the RPZ directives.

**Status:** Architectural constraint (dnsconfd limitation); workaround
in place.

---

### 7. Unbound RPZ requires `respip` module in `module-config`

**Symptoms:** RPZ zones are configured correctly but Unbound does not
apply RPZ response policy rewriting. Blocked domains still resolve
normally.

**Root Cause:** Unbound's RPZ feature depends on the `respip` module
being loaded. Without `respip` in the `module-config` directive, RPZ
zone data is loaded but never consulted during query resolution.

**Fix:** Update the `zz-module-override.conf` drop-in to set
`module-config: "respip validator iterator"`. The `respip` module
must appear before `validator` in the module chain.

**Validation:** `unbound-control status` shows `respip` in the module
list; `dig` queries for RPZ-blocked domains return `NXDOMAIN`.

**Status:** Fixed.

---

## Vault

### 8. Vault Agent `systemctl: command not found` in `vault_t` PATH

**Symptoms:** Vault Agent's template `command` hook fails with
`systemctl: command not found` when attempting to reload services
after certificate rotation.

**Root Cause:** The `vault_t` SELinux domain has a restricted `PATH`.
When Vault Agent spawns a shell to run the template command, the
shell's `PATH` does not include `/usr/bin/` where `systemctl`
resides. The bare command `systemctl` is not resolved.

**Fix:** Use the full path `/usr/bin/systemctl` in all Vault Agent
template command hooks (e.g., `/usr/bin/systemctl reload vault`).

**Validation:** Vault Agent template commands execute successfully;
`journalctl -u vault-agent` shows clean reload operations.

**Status:** Fixed.

---

### 9. `ProtectSystem=full` blocks proxy cert writes

**Symptoms:** Vault Agent fails to write renewed TLS certificates to
`/etc/nginx/certs/` with "Permission denied" errors, despite the
`vault_t` SELinux policy allowing `httpd_config_t` file writes.

**Root Cause:** The Vault Agent systemd unit uses
`ProtectSystem=full`, which makes `/etc/` read-only at the mount
namespace level. SELinux policy is irrelevant when the filesystem
mount is read-only.

**Fix:** Add `ReadWritePaths=/etc/nginx/certs` to the Vault Agent
systemd unit file, creating a targeted exception to
`ProtectSystem=full` for the certificate directory only.

**Validation:** Vault Agent writes certs successfully;
`ls -la /etc/nginx/certs/` shows updated timestamps after rotation.

**Status:** Fixed.

---

## SELinux

### 10. SELinux policy handler not firing on partial re-runs

**Symptoms:** After a partial playbook re-run (e.g., with `--tags`),
the SELinux policy compilation handler does not fire even though
policy source files have changed.

**Root Cause:** Ansible handlers only fire when notified by a task
that actually ran in the current play. If the task that deploys the
`.te` source file is skipped (due to tags or `when` conditions), the
handler is never notified, leaving a stale compiled policy.

**Fix:** Add an explicit `semodule -l | grep <module>` check task
that runs unconditionally (or with `tags: always`) and compares the
installed module against the source. If they differ, the task
notifies the compile handler directly.

**Validation:** Run with `--tags selinux`; confirm the policy module
version matches the source `.te` file.

**Status:** Fixed.

---

## Ansible

### 11. `remote_tmp` SELinux context stale after reboot

**Symptoms:** After Phase 2 hardening maps the admin to `staff_u`,
subsequent playbook runs fail during "Gathering Facts" with
permission errors on `/root/.ansible/tmp`.

**Root Cause:** The `remote_tmp` directory was created during the
initial (pre-hardening) run under `unconfined_u`, giving it
`admin_home_t` context. After hardening, the SSH admin transitions to
`sysadm_t`, which cannot write to `admin_home_t` directories.

**Fix:** A `raw` pre-task in Phase 0 runs `restorecon -F` on the
`remote_tmp` directory with `tags: always`, ensuring the SELinux
context is corrected on every playbook run before fact gathering.

**Validation:** Playbook runs succeed after reboot; `ls -Z
/root/.ansible/tmp` shows correct context.

**Status:** Fixed.

---

### 12. Avahi `use-chroot` invalid config key

**Symptoms:** Avahi daemon fails to start or logs warnings about an
unknown configuration key `use-chroot` in `avahi-daemon.conf`.

**Root Cause:** The `use-chroot` option was removed or is not
recognized in certain Avahi builds. The Avahi systemd unit may
already pass `--no-chroot` via the command line, making the config
key redundant and potentially conflicting.

**Fix:** Remove the `use-chroot` key from the `avahi-daemon.conf`
template. Instead, ensure the systemd unit override passes
`--no-chroot` on the command line, which is the supported mechanism
for disabling chroot in modern Avahi.

**Validation:** `systemctl status avahi-daemon` shows active with no
warnings; `avahi-browse -a` discovers local services.

**Status:** Fixed.

---

## E2E Validation Session Fixes

### 13. vault-ssh-helper has no RPM package upstream

**Symptoms:** `dnf install vault-ssh-helper` fails; no Fedora or
HashiCorp repository provides an RPM for vault-ssh-helper.

**Root Cause:** HashiCorp does not publish vault-ssh-helper as an RPM
package. It is only distributed as a standalone binary release from
GitHub.

**Fix:** Switched to a direct binary download using `get_url` in
`roles/auth/tasks/main.yml`. The binary is fetched from GitHub
releases and installed to `/usr/local/bin/vault-ssh-helper`.

**Validation:** `vault-ssh-helper -verify-only -config /etc/vault-ssh-helper.d/config.hcl`
returns successfully; PAM OTP authentication works end to end.

**Status:** Fixed. **Backlog note:** The download currently has no
SHA-256 checksum verification — a supply-chain hardening gap. Add a
`checksum:` parameter to the `get_url` task or document the accepted
risk.

---

### 14. Audit rules file-ordering bug — 99-local-cross-field.rules

**Symptoms:** Two CIS 4.1.15 privilege-escalation audit rules silently
disappear on every auditd restart, despite being present in the
deployed rules files.

**Root Cause:** `99-local-cross-field.rules` sorted lexicographically
before `custom.rules`, which contains a leading `-D` (delete all)
directive. On auditd load, the `-D` in `custom.rules` wiped the rules
from `99-local-cross-field.rules` that were loaded just before it.

**Fix:** Renamed `99-local-cross-field.rules` to
`zz-local-cross-field.rules`, ensuring it sorts after `custom.rules`
and its `-D` directive.

**Validation:** `auditctl -l | grep -c .` returns 50 rules (previously
lost 2); rules persist across auditd restarts.

**Status:** Fixed.

---

### 15. LUKS false-negative in preflight and verification

**Symptoms:** The LUKS full-disk encryption preflight check passes on
systems without LUKS when the root filesystem sits on an LVM logical
volume.

**Root Cause:** The original check used `lsblk -o PKNAME` with a
single hop, which resolves only the immediate parent device. On
LVM-over-LUKS layouts, the parent is the LVM PV device (e.g.,
`dm-0`), not the underlying LUKS container. The LUKS layer is two
hops down.

**Fix:** Replaced the single-hop `lsblk -o PKNAME` with an
`lsblk -s` ancestor-chain walk that traverses the entire device stack
from the root filesystem back to the physical disk, checking each
ancestor for `TYPE=crypt`.

**Validation:** Check correctly detects LUKS on LVM-over-LUKS layouts
and fails on unencrypted systems. Tested in both
`roles/common/tasks/preflight.yml` and
`roles/verification/tasks/main.yml`.

**Status:** Fixed.

---

### 16. SSH credential gateway 502 Bad Gateway

**Symptoms:** OTP credential requests through the SSH credential
gateway (port 8443) return HTTP 502 Bad Gateway. Vault itself is
healthy and responding on `127.0.0.1:8200`.

**Root Cause:** The Nginx proxy configuration in
`vault-ssh-gateway.conf.j2` was missing the `proxy_ssl_name` directive.
Nginx connected to Vault using the upstream IP (`127.0.0.1`) as the SNI
hostname, but the Vault TLS certificate's SAN contains `vault.local`,
not `127.0.0.1`. The TLS SAN mismatch caused the upstream connection to
fail.

**Fix:** Added `proxy_ssl_name vault.local;` to the gateway's
`location` block, ensuring Nginx sends the correct SNI hostname that
matches the Vault certificate SAN.

**Validation:** `curl -s -o /dev/null -w '%{http_code}' https://<host>:8443/v1/ssh-otp/creds/daily`
returns 200 (with valid Vault token); gateway proxies to Vault
successfully.

**Status:** Fixed.

---

### 17. SSH gateway config notified wrong handler

**Symptoms:** After changing the SSH credential gateway Nginx
configuration, the new config is not picked up until a manual
`systemctl reload nginx` is run.

**Root Cause:** The gateway config template task notified the
`Reload proxy systemd units` handler, which only runs
`systemctl daemon-reload` — it does not reload Nginx itself. The
correct handler is `Reload nginx`, which runs
`systemctl reload nginx`.

**Fix:** Changed the `notify` target in the gateway config template
task from `Reload proxy systemd units` to `Reload nginx`.

**Validation:** Modifying the gateway template and re-running the
playbook results in an immediate Nginx reload; `nginx -T` shows the
updated configuration.

**Status:** Fixed.

---

### 18. Vault SELinux semodule -l idempotency bug

**Symptoms:** The Vault SELinux policy compilation task always reports
`changed` on every playbook run, even when the policy module is
already installed and up to date.

**Root Cause:** The `changed_when` condition checked for the substring
`'vault '` (with a trailing space) in `semodule -l` output. Modern
`semodule -l` output format does not include a trailing space after
the module name, so the substring match never succeeded, causing the
task to always evaluate as changed.

**Fix:** Changed the idempotency check to iterate `stdout_lines` and
match the exact token `'vault'` in the line, rather than relying on
substring matching with a trailing space.

**Validation:** Running the playbook twice in succession shows the
SELinux policy task as `ok` (not `changed`) on the second run.

**Status:** Fixed.

---

### 19. authselect idempotency and upstream tlog limitation

**Symptoms:** The `authselect select` task always reports `changed`
on every playbook run, even when the desired profile is already
active.

**Root Cause:** `authselect select --force` unconditionally rewrites
configuration files regardless of current state, and Ansible's
`command` module has no built-in way to detect a no-op. Additionally,
the upstream `linux-system-roles.tlog` role runs its own
`authselect select` which can drop features set by the auth role
(e.g., `with-faillock`, `with-pamaccess`).

**Fix:** Added an `authselect current` pre-check task that parses
the active profile and enabled features. The `authselect select` task
is skipped (with `when`) if the desired profile and all features are
already active. The auth role is sequenced after `tlog` in the
playbook to re-assert the complete feature set.

**Validation:** Running the playbook twice shows the authselect task
as `skipped` on the second run. All features (`with-tlog`,
`with-faillock`, `with-pamaccess`, `with-pwhistory`, `without-nullok`)
remain active.

**Status:** Fixed (authselect idempotency). **Note:** The upstream
`linux-system-roles.tlog` limitation is documented but unfixed —
ordering dependency is the mitigation.

---

### 20. Plymouth boot hang after LUKS unlock

**Symptoms:** After entering the LUKS passphrase at boot, the system
hangs for approximately 79 seconds before continuing. The
`plymouth-read-write.service` unit times out waiting.

**Root Cause:** `plymouthd` never sent the `SIGRTMIN+20` ready signal
to systemd, causing `plymouth-read-write.service` to block until its
timeout expired. This is a known Plymouth/systemd interaction issue on
certain Fedora configurations.

**Fix:** Added `plymouth.enable=0` to the kernel command line via the
bootloader role's `kernel_settings_sysctl` configuration. This
disables Plymouth entirely, eliminating the hang. Also removed the
`quiet` kernel parameter to restore visible boot text (required
because Plymouth was providing the graphical boot splash that masked
boot messages).

**Validation:** System boots without delay after LUKS unlock; `dmesg`
and boot messages are visible on console; no Plymouth-related systemd
units are active.

**Status:** Fixed.

---

### 21. CA-trust / NSS-import and yum_repository gpgkey idempotency

**Symptoms:** Multiple tasks report `changed` on every playbook run:
`update-ca-trust`, `certutil` NSS database import, and
`yum_repository` tasks with multi-value `gpgkey` parameters.

**Root Cause:** Two separate issues:

1. The `update-ca-trust` and `certutil` tasks used unconditional
   `changed_when: true`, forcing Ansible to always report them as
   changed regardless of actual state.
2. The `yum_repository` module expects `gpgkey` as a newline-delimited
   string, but the variable was defined as a YAML list. Ansible
   serialized the list into a string with different formatting than
   what `yum_repository` wrote to the `.repo` file, causing a
   round-trip mismatch that triggered a rewrite every run.

**Fix:**

1. Replaced unconditional `changed_when: true` on CA-trust and NSS
   tasks with a handler + `meta: flush_handlers` pattern: the
   certificate deploy task notifies a handler that runs
   `update-ca-trust` and `certutil` only when the certificate file
   actually changes.
2. Changed the `gpgkey` variable from a YAML list to a
   newline-delimited string in YAML literal block scalar format,
   matching the format `yum_repository` writes to disk.

**Validation:** Running the playbook twice shows CA-trust, NSS-import,
and yum_repository tasks as `ok` (not `changed`) on the second run.

**Status:** Fixed.

---

## Backlog / Future Work

Deferred items tracked for future implementation. These are not
blocking the current plan and are listed in rough priority order.

### SELinux Option B — Dedicated `vault_ssh_helper_t` Domain Transition

The current SELinux implementation (Option A) widens `sshd_t` to allow
connections to `vault_cluster_port_t` for OTP validation. The long-term
plan is a dedicated `vault_ssh_helper_t` domain transition that
confines `vault-ssh-helper` to its own SELinux domain, following the
principle of least privilege. This requires careful iteration on
fd/fifo/signal permissions (`allow vault_ssh_helper_t sshd_t:fd use;`
etc.), likely 2–3 AVC-denial-driven passes. See
[ADR-0005](decisions/ADR-0005-vault-ssh-otp-ca.md) for context.

### SSHGuard — Network-Level IP Blocking

Network-level IP-blocking complement to `pam_faillock`'s account-level
lockout. Lower marginal value today (firewall already restricts SSH to
`bastion_ip`), becomes more valuable once VPN widens the set of
legitimate remote sources. Sequence after VPN implementation.

### VPN/IPsec + MACsec Synergy

IKEv2 certificates can reuse the existing Vault PKI root+intermediate
chain directly (new `pki_int/issue/ipsec-peer` role, zero new CA).
MACsec CAK/CKN pairs are a natural fit for the existing Vault KV
`secret/` mount. Both would reuse the Vault Agent template
auto-renewal pattern and the CA-rotation overlap-window runbook
developed for the SSH CA. The SELinux Option A/B decision framework is
directly reusable for whatever daemon (libreswan, MACsec key manager)
needs to reach Vault's port next.

### Break-Glass Cert Auto-Renewal

Extend Vault Agent's `template` stanza (same mechanism already proven
for the TLS leaf cert) to pre-render a fresh break-glass SSH
certificate to local disk on a cadence inside the 72h max TTL, so
break-glass access does not depend on a human remembering to re-issue
it at the moment of crisis.

### Ansible-Vault Password TPM2+age Layering

Beyond the urgent plaintext fix (plain `ansible-vault encrypt` +
`.vault_pass.txt`), seal that controller-side password with
`systemd-creds --with-key=tpm2`, mirroring the exact pattern already
used for the Vault age identity file, decrypted via a wrapper script
referenced by `ansible.cfg`'s `vault_password_file`.

### Static Key Narrowing (Interim, Pre-Gateway)

Before the full SSH credential gateway lands, consider restricting
the existing static key in `authorized_keys` with a `command=` option
to reduce its blast radius, without requiring the gateway to exist yet.

### CIS/STIG Framework Research

Formally research CIS, DISA STIG, NIST 800-53, and other applicable
frameworks and produce a definitive compliance mapping document (single
framework or explicitly-documented hybrid) so every control in the
codebase cites an accurate, independently-verified ID rather than
ad-hoc citations added during implementation.

Corrected CIS RHEL 9 v3.0.0 control IDs currently used in this project:

| Control                     | CIS ID    | Description                                           |
|-----------------------------|-----------|-------------------------------------------------------|
| Faillock module enablement  | 5.3.2.2   | Ensure pam_faillock module is enabled                 |
| Faillock deny/unlock values | 5.3.3.1.x | Ensure password failed attempts lockout is configured |
| Pwquality minimum length    | 5.3.3.2.2 | Ensure password length is configured                  |
| Pwhistory remember          | 5.3.3.3.1 | Ensure password history remember is configured        |

**Note:** Earlier drafts incorrectly cited 5.4.1 and 5.4.4 — those are
shadow password suite parameters (password aging), not PAM controls.

This workload also absorbs the following sub-items deferred from the
active plan:

- **Shell idle timeout** — `TMOUT=900` via `/etc/profile.d/`
  (CIS 5.6.4)
- **Concurrent session limits** — `maxlogins` via
  `/etc/security/limits.d/` (CIS 5.6.5)
- **GDM/GNOME auto-lock** — dconf lockdown for idle lock + lock-delay
  (CIS 1.8.x)
- **`su` restriction** — restrict to wheel group via `pam_wheel.so` in
  `/etc/pam.d/su` (CIS 5.2.7)
- **GDM warning banner** — graphical login banner (not just SSH)
  (CIS 1.8.2)
- **Cron/at restriction** — `/etc/cron.allow`, `/etc/at.allow`
  (CIS 5.1.8–9)

### IMA (Integrity Measurement Architecture)

Kernel-level continuous integrity measurement, available on
RHEL 10 / Fedora 44. Measures executables and libraries at execution
time (not periodically like AIDE), refuses to execute files whose
signatures do not match (in appraisal mode), and extends TPM PCRs for
Keylime remote attestation. Chains with the project's existing stack:

```text
fapolicyd (path-based trust)
  → IMA (content-based signature verification)
    → AIDE (periodic baseline scan)
      → Keylime (external attestation)
```

Enable via
`ima-setup --policy=/usr/share/ima/policies/01-appraise-executable-and-lib-signatures`.
Requires testing for fapolicyd interaction (both restrict execution,
verify no double-deny) and understanding the dracut module requirement
for boot-time policy loading. Dedicate an ADR once evaluated.

### TPM2 PCR-Bound Vault Unseal Credentials

Strengthen auto-unseal by binding the age identity credential to
specific boot-chain PCR values
(`systemd-creds encrypt --with-key=tpm2 --tpm2-pcrs=7+11`), not just
TPM chip presence. This means the credential only decrypts if the
system booted with the expected kernel/initrd/bootloader — a USB
live-boot attacker with physical access to the same TPM chip would get
different PCR values and the credential stays sealed.

Caveat: kernel updates change PCR values, requiring re-sealing before
reboot. `systemd-measure` can pre-calculate expected PCR values for
new UKI images. Worth an ADR documenting the capability and the
kernel-update operational procedure.

### Secure Boot Verification

Add a check in the verification role to confirm Secure Boot is actually
enabled. The project sets `audit=1` in bootloader params but does not
verify Secure Boot status. This is a critical prerequisite for IMA
appraisal and TPM2 PCR binding to be meaningful.

### USBGuard Class-Based Policy Refinement

Currently whitelists all plugged-in devices at deploy time. Could
restrict to HID-only (keyboard/mouse) and block mass-storage USB class
to prevent BadUSB and data-exfiltration attacks.

### Vault Telemetry

Enable the `telemetry` stanza in `vault.hcl` for
Prometheus-compatible metrics. Zero-cost to enable (no scraper
required), provides future observability capability per HashiCorp's
hardening checklist.

### AIDE `/boot/efi` SELinux `dosfs_t` Denial

`aide_t` lacks `getattr` permission on the `vfat` filesystem class,
causing AVC denials when AIDE scans `/boot/efi`. The AIDE baseline
still succeeds (denials are non-fatal), but the AVC log noise is
undesirable. Options: exclude `/boot/efi` in `aide.conf`, or write a
scoped `.te` rule granting `aide_t` the minimal permission.

### fapolicyd GDM Socket Denial

During deploy-time trust-database rebuilds, fapolicyd briefly denies
GDM's access to a Unix socket. This occurs only during the initial
`fapolicyd-cli --update` triggered by Ansible and has zero recurrence
on a clean reboot. fapolicyd stays active and enforcing throughout.
No fix required unless the denial becomes reproducible outside
deploy-time conditions.

### `aide_init: true` Baseline Refresh Every Deploy

The `aide_init: true` variable causes AIDE to regenerate its baseline
database on every Ansible run. This is intentional: the baseline
represents the last Ansible-applied state, ensuring that any
configuration drift between deploys is detected. Genuine file
integrity monitoring relies on the independent `aide_cron_check`
systemd timer, which runs daily against the last-deployed baseline.
This is a design tradeoff, not a bug.
