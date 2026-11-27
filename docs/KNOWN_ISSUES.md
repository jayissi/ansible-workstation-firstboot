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

**Do not reorder to `validator respip iterator`** (attempted 2026-11-24
in response to a CVE-2026-50243 "validate before rewrite" write-up).
Unbound 1.26.2 rejects that order at startup:
`unbound-checkconf: fatal error: module conf 'validator respip iterator'
is not known to work`, and `unbound.service` fails, taking local DNS
down. Unbound modules form a stack: the query descends the list and the
answer ascends it in reverse, so with `respip validator iterator` the
validator already sees (and SERVFAILs) a BOGUS answer before `respip`
can rewrite it. Verified on testfedora with the original order:
`isc.org` / `fedoraproject.org` NOERROR + AD, `dnssec-failed.org`
SERVFAIL, RPZ-listed `0-02.net` NXDOMAIN. Mitigate CVE-class issues in
this area by keeping `unbound` patched (`dnf upgrade unbound`), not by
reordering modules.

**Recovery note:** the dns role used to re-download `root.hints` on
every run, which needs working DNS, so a broken resolver config could not
be repaired by re-running the role. Since 2026-11-25 the download only
runs when the file is missing (the `unbound-root-hints` timer refreshes
it), so `ansible-playbook playbooks/site.yml --tags dns` can repair a
bad drop-in.

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

**Status:** Fixed. SHA-256 checksum now pins the download
(`checksum: sha256:{{ auth_vault_ssh_helper_checksum }}` in
`roles/auth/tasks/install.yml`, with `validate_certs: false`
compensated by the pinned checksum). Inline `checkov` skip annotation
documents the accepted risk.

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

### 22. AIDE baseline silently overwritten on every deploy

**Symptoms:** `aide --init` ran on every Ansible deploy, silently
overwriting the integrity baseline database. AIDE's daily integrity
check (`aide_cron_check` timer) always compared against a
minutes-old baseline, making it unable to detect persistent
unauthorized changes.

**Root Cause:** `aide_init: true` was set statically in
`inventory/group_vars/all/main.yml`, unconditionally triggering
`aide --init` on every run. The previous documentation incorrectly
described this as "intentional" — it was a bug that defeated
file-integrity monitoring.

**Fix:** `playbooks/site.yml` Phase 3 `pre_tasks` now stats
`/var/lib/aide/aide.db.gz` and sets `aide_init` dynamically via
`set_fact` — `true` only on first bootstrap (database absent),
`false` on subsequent runs.

**Validation:** `mtime` + checksum of `aide.db.gz` are identical
before and after a deploy once the baseline exists (post-fix).

**Status:** Fixed.

---

### 23. SSH OTP 4-layer non-functionality

**Symptoms:** SSH OTP login via vault-ssh-helper was completely
non-functional despite being documented as a feature. A Vault-issued
OTP was rejected at every attempt.

**Root Cause:** Four stacked bugs, each only visible after fixing
the previous one:

1. **Orphaned PAM file** — PAM content was deployed to
   `/etc/pam.d/vault-ssh-helper`, which sshd never references
   (OpenSSH hardcodes the PAM service name to `sshd`).
2. **Log file DAC** — `/var/log/vault-ssh-helper.log` could not be
   created by sshd's pre-auth worker (unprivileged process, cannot
   create files in `/var/log/` with `0755` permissions).
3. **Wrong SELinux domain** — the SELinux module targeted `sshd_t`
   (listener), but Fedora 44's OpenSSH 10.2p1 re-exec architecture
   runs the PAM stack under `sshd_session_t` (per-connection domain).
4. **Hidden dontaudit'd `open` permission** — `sshd_session_t`
   needed `open` on `var_log_t:file`, but the denial was suppressed
   by a `dontaudit` rule (required `semodule -DB` to surface).

**Fix:** Moved PAM content into `/etc/pam.d/sshd`. Pre-created the
log file with `root:sshd 0620` permissions. Updated
`sshd-vault-ssh-helper.te` to v1.2.0 covering `sshd_session_t` with
`file { open append }`.

**Validation:** Real Vault-issued OTP → successful SSH login
confirmed end-to-end.

**Status:** Fixed.

---

### 24. Break-glass SSH cert rendering crash-loop

**Symptoms:** Vault Agent's break-glass SSH certificate template
continuously failed to render, preventing break-glass cert
provisioning entirely.

**Root Cause:** `breakglass-ssh-cert.tpl.j2` hardcoded
`~/.ssh/id_ed25519.pub` which did not exist (admin used a
project-specific key). Additionally, the `vault` user (uid=963) could
not traverse the admin's `0700` home directory regardless.

**Fix:** Ansible task extracts the admin's trusted public key from
`authorized_keys` and deploys it to
`/etc/vault.d/certs/breakglass-admin-pubkey.pub` (`vault:vault 0440`).
Template updated to read from that vault-accessible path.

**Validation:** Break-glass SSH certificate successfully rendered for
the first time.

**Status:** Fixed.

---

### 25. vault-agent-secret `RemainAfterExit` preventing re-provisioning

**Symptoms:** After restarting `vault-agent`, the AppRole `secret_id`
file was missing. `vault-agent-secret.service` showed
`active (exited)` but its `ExecStart` never re-ran.

**Root Cause:** `RemainAfterExit=true` on the AppRole secret_id
decrypt oneshot caused systemd to consider the unit "already
satisfied" on subsequent `vault-agent` restarts. The `ExecStart`
(which decrypts the TPM2-sealed secret_id ciphertext) never re-ran,
leaving `vault-agent` with no `secret_id` file.

**Fix:** Removed `RemainAfterExit` from
`vault-agent-secret.service`.

**Validation:** Self-healing verified — restarting `vault-agent`
alone auto-triggers `vault-agent-secret` via the
`Requires=` / `Before=` dependency chain, re-provisioning the
`secret_id` file.

**Status:** Fixed.

---

### 26. P-384 Root/Intermediate CA silently stuck at P-256

**Symptoms:** Despite `vault_pki_key_type: ec` being set, Root CA
and Intermediate CA certificates were generated with P-256 curves
instead of the intended P-384 (CNSA 2.0).

**Root Cause:** `pki_engine.yml`'s Root CA
(`pki/root/generate/internal`) and Intermediate CSR
(`pki_int/intermediate/generate/internal`) tasks specified `key_type`
but were **missing** the `key_bits` parameter. Vault silently
defaults to P-256 for EC keys when `key_bits` is omitted.

**Fix:** Added `key_bits: '{{ vault_pki_key_bits }}'` (384) to both
the Root CA generation and Intermediate CSR generation tasks.

**Validation:** Regenerated full CA chain; all 5 certificate types
(Root CA, Intermediate CA, vault-server, nginx-gateway, client-auth)
confirmed P-384 via `openssl x509 -noout -text | grep ASN1 OID`.

**Status:** Fixed.

---

### 27. pam_unix invalid `not_set_pass` option

**Symptoms:** Every SSH login generated a PAM error about an invalid
option, logged to the authentication journal.

**Root Cause:** Orphaned, never-tested PAM content included
`not_set_pass` which is not a valid `pam_unix` option.

**Fix:** Removed the invalid option, keeping the valid
`use_first_pass nodelay`.

**Validation:** SSH login proceeds without PAM errors in the journal.

**Status:** Fixed.

---

### 28. Lint infrastructure 8-fix sweep

**Symptoms:** Multiple linter failures when running `make lint`
against the full repository. CI pipeline had a placeholder path
mismatch. False positives on legitimate acronyms.

**Root Cause:** The `collections/` vendored directory was not
excluded from 6 linter configurations (yamllint, ruff, pyright,
markdownlint-cli2, codespell scan args, checkov skip-path).
Additional issues: `vault_pass.txt` missing from `Containerfile`
`CMD` (CI had placeholder, local Podman path did not match), codespell
false positives on AER/UE hardware acronyms, and checkov inline skip
needed for vault-ssh-helper `validate_certs: false` (compensated by
pinned SHA-256 checksum).

**Fix:** Added `collections/` exclusions to all 6 tool configs.
Fixed `vault_pass.txt` path in `Containerfile`. Added AER/UE to
codespell's ignore-words list. Added inline checkov skip annotation
with compensating-control justification.

**Validation:** `make lint` passes cleanly across all tools.

**Status:** Fixed.

---

### 29. Browser TLS client certificate auth, managed bookmarks, and Vault status endpoint

**Symptoms:** Selecting "TLS Certificates" on the Vault UI login page
returned "Authentication failed: client certificate must be supplied."
Firefox and Chrome never prompted for a client certificate. Browsers had
no bookmark bar shortcuts to the Vault UI or health endpoint. VaultPass
and uBlock Origin extensions were hidden in the overflow menu.

**Root Cause:** Neither Vault's listener (`vault.hcl`) nor Nginx
(`vault-proxy.conf`) was configured to request a client certificate
during the TLS handshake. Without a `CertificateRequest` in the
handshake, browsers never prompt for a cert, and Vault's `auth/cert/login`
endpoint always fails. Additionally, VaultPass's `background.js`
crashes on Firefox with `importScripts is not defined` (a Chrome
Manifest V3 API not available in Firefox's Manifest V2 background
scripts), breaking the "Login via Web" button entirely — this is a
third-party extension bug, not a project infrastructure issue.

**Fix:**

- Implemented the Nginx re-encryption architecture: browsers present
  their TLS client certificate to Nginx (`ssl_verify_client optional`),
  Nginx validates it against the CA chain and CRL, then forwards the
  URL-encoded certificate to Vault via the `X-Client-Cert` header
  (`proxy_set_header X-Client-Cert $ssl_client_escaped_cert`). Vault
  reads the forwarded certificate through its
  `x_forwarded_for_client_cert_header` listener parameter, enabling
  `auth/cert/login` to authenticate the client without requiring a
  direct TLS connection to Vault. This allows cert auth to work through
  `https://vault.local` (Nginx proxy) in both Firefox and Chrome.
- Added `tls_client_ca_file` to Vault's listener template
  (`vault.hcl.j2`) pointing to the Root CA so Vault sends a
  `CertificateRequest` listing the Root CA as trusted.
  `tls_require_and_verify_client_cert` is deliberately not set (defaults
  to `false`) so the Vault UI loads without a cert; cert auth only
  activates on explicit login.
- Header sanitization in `vault-proxy.conf.j2`: Nginx clears any
  incoming `X-Client-Cert` header from the client before setting it
  from the validated TLS handshake result, preventing header injection.
- Added managed bookmarks ("Vault" and "Vault Status") to both Firefox
  and Chrome via enterprise policies. Bookmark bar forced visible via
  `DisplayBookmarksToolbar: "always"` (Firefox) and
  `BookmarkBarEnabled: true` (Chrome).
- Pinned VaultPass and uBlock Origin to the browser toolbar in both
  browsers: `default_area: "navbar"` (Firefox) and
  `toolbar_pin: "force_pinned"` (Chrome). Visible in regular and
  private/incognito mode.
- Created `status.vault.local` DNS record and Nginx vhost that proxies
  to Vault's `/v1/sys/health` endpoint. Added `status.vault.local` as
  a SAN to the Nginx Gateway certificate.
- Migrated Chrome extension policies from `ExtensionInstallForcelist`
  to `ExtensionSettings` format (supports toolbar pinning). Removed
  legacy `extensions.json` and `incognito-extensions.json`.

**Validation:** `make lint` passes. Deploy to VM, verify Vault UI loads
at `https://vault.local`, TLS Certificates login prompts for client
cert in both Firefox and Chrome, cert auth succeeds through the Nginx
re-encryption proxy, bookmarks appear in bookmark bar,
`https://status.vault.local` returns Vault health JSON.

**Status:** Fixed.

---

### 30. Vault syslog audit backend fails under `vault_t` SELinux domain

**Symptoms:** Vault returns HTTP 500 on ALL API requests after reboot.
`vault audit enable syslog` fails with "error writing to syslog: write
unixgram @->/run/systemd/journal/dev-log: write: permission denied".
`ausearch -m avc` shows zero denials.

**Root Cause:** The custom `vault_t` SELinux domain had zero
`unix_dgram_socket` permissions for the `devlog_t` target type. When a
domain has no rules at all for an object class (not even `dontaudit`),
the SELinux kernel module denies access but may not emit an AVC audit
record — making the denial invisible to `ausearch` and `audit2allow`.
Confirmed via `sesearch -A -s vault_t -c unix_dgram_socket` returning
empty results, and `seinfo -a syslog_client_type -x | grep vault`
confirming vault_t was NOT in the `syslog_client_type` attribute. Vault
requires ALL audit backends to succeed; when syslog failed, every API
request returned 500 (by design). Same failure class as
hashicorp/vault#31670 (AppArmor on Ubuntu).

**Fix:** Added `devlog_t` type to the require block and
`allow vault_t devlog_t:unix_dgram_socket sendto;` to `vault.te`. Also
added `write` to `self:unix_dgram_socket` class declaration. Bumped
policy to v1.4.0.

**Validation:** `vault audit enable syslog tag=vault-audit facility=AUTH`
succeeds. `vault audit list` shows both `file/` and `syslog/` backends.
`journalctl -t vault-audit` shows audit entries.

**Status:** Fixed.

---

### 31. VaultPass NetworkError on Firefox (cert dialog blocks extension fetch)

**Symptoms:** VaultPass popup shows "NetworkError when attempting to
fetch resource" or "No matching key found for this page" despite API
calls returning 200 in Nginx access logs. VaultPass DevTools Network tab
(via about:debugging) shows successful LIST and READ requests, but the
popup never renders matched credentials.

**Root Cause:** Nginx's `ssl_verify_client optional` triggers a TLS
`CertificateRequest` during connection establishment. Firefox prompts
for a client certificate separately for the page context
(`https://vault.local`) and the extension context
(`moz-extension://...`). The second cert dialog for the extension origin
blocks VaultPass's `fetch()` calls, causing a NetworkError if the user
doesn't respond quickly enough or the popup closes.

**Fix:** Firefox enterprise policy sets
`security.default_personal_cert = "Select Automatically"` (locked).
Firefox auto-selects the client certificate without prompting for any
origin, eliminating the dialog that blocked VaultPass. Chrome equivalent:
`AutoSelectCertificateForUrls` policy with issuer filter
`O=Local Lab Infrastructure`.

**Validation:** VaultPass popup Keys tab displays matched credentials
with copy/fill buttons. No cert dialog appears. VaultPass "Add Key" and
"Save Key" work end-to-end.

**Status:** Fixed.

---

### 32. Chrome Manifest V2 extension deprecation (uBlock Origin + VaultPass)

**Symptoms:** Chrome extensions page shows no installed extensions
despite `force_installed` enterprise policy. Chrome Web Store shows
"This item's installation is required by your organization" but errors
with "blocked by the administrator." Chrome version 156.

**Root Cause:** Chrome 139+ fully removed Manifest V2 extension support.
The `ExtensionManifestV2Availability` enterprise policy was removed in
Chrome 139. Both uBlock Origin (`cjpalhdlnbpafiamejdnhcphjbkeiagm`) and
VaultPass (`kbndeonibamcpiibocdhlagccdlmefco`) were MV2-only at the
time of testing (Chrome 156, October 2026).

**Fix:** Originally removed all Chrome extension policies (MV2-only at
time of testing). After confirming VaultPass v2.3.5+ on Chrome Web
Store is Manifest V3, re-enabled VaultPass as a force-installed Chrome
extension with toolbar pinning. uBlock Origin remains excluded (MV2-only;
uBlock Origin Lite is the MV3 alternative but is a different extension).

**Validation:** No extension-related errors in Chrome. Chrome policies
clean (bookmarks.json + dns-security.json only).

**Status:** Fixed (architectural constraint — MV2 is permanently removed
from Chrome).

**Update (CAB review):** VaultPass v2.7 on GitHub master and v2.6 on
Firefox AMO are now **Manifest V3**. The Chrome Web Store version
(v2.3.5) is also MV3. This means VaultPass may now work on Chrome 139+.
The `importScripts` crash in `background.js` is no longer a bug — it is
a valid Web Worker API call within an MV3 service worker context.
Re-evaluate Chrome VaultPass deployment after confirming the AMO/CWS
versions are MV3-compatible with the deployed Vault configuration.
uBlock Origin remains MV2-only on Chrome (uBlock Origin Lite is the
MV3 alternative but is a different extension).

---

### 33. Vault audit log rotation SELinux denial

**Symptoms:** `logrotate.service` fails with
`error: stat of /var/log/vault/audit.log failed: Permission denied`.
`systemctl list-units --state=failed` shows logrotate as failed.

**Root Cause:** The Vault audit log files carry the `vault_log_t` SELinux
label. The `logrotate_t` SELinux domain has no rules allowing access to
`vault_log_t` files. The `su vault vault` logrotate directive switches
the Unix UID but logrotate's SELinux process context remains
`logrotate_t`, which still cannot access `vault_log_t` objects.

**Fix:** Created `logrotate-vault.te` SELinux module granting
`logrotate_t` read/write/rename/unlink on `vault_log_t` files and
search/read on `vault_log_t` directories. Logrotate config updated to
use `copytruncate` (truncates in-place, avoids file creation with wrong
SELinux labels) and `su vault vault`.

**Validation:** `logrotate -d /etc/logrotate.d/vault-audit` succeeds
with no permission errors. `systemctl list-units --state=failed` shows
no logrotate failure.

**Status:** Fixed.

---

### 34. CRL bootstrap `validate_certs` disabled (checkov CKV_ANSIBLE_2)

**Symptoms:** checkov linter fails with
`CKV_ANSIBLE_2: Ensure that certificate validation isn't disabled with get_url`
on the CRL bootstrap task.

**Root Cause:** The CRL bootstrap used `ansible.builtin.get_url` with
`validate_certs: false` to fetch the CRL from localhost Vault, which
uses the project's private CA. The `get_url` module doesn't support
`ca_path` for custom CA trust.

**Fix:** Replaced `get_url` with `ansible.builtin.uri` using
`ca_path: /etc/nginx/certs/root.crt` for proper TLS validation against
the private CA. URL changed from `127.0.0.1:8200` to
`vault.local:8200` to match the certificate's SAN. Two-step fetch:
`uri` returns content, `copy` writes it to disk.

**Validation:** All 18 linters pass with zero suppressions. CRL
bootstrap validates TLS against the private Root CA.

**Status:** Fixed.

---

### 35. Fresh install: Vault started with the HashiCorp RPM's default config

**Symptoms:** On a freshly reinstalled host, `vault operator init` failed
(output hidden by `no_log`). Vault's journal showed `Storage: file`, no
`api_addr`, and a listener on `0.0.0.0:8200` -- not the project config.

**Root Cause:** The `vault` RPM ships its own `/etc/vault.d/vault.hcl`.
`install.yml` flushes handlers early (to load the SELinux module), and
that handler notified `Restart vault`, which **started** Vault with the
package config before the project `vault.hcl` existed. The later
"start Vault" task was then a no-op.

**Fix:** `Restart vault` only runs once `_deploy_vault_hcl.yml` has
deployed the project config in this play (`__vault_hcl_deploy`), and
`init.yml` flushes handlers immediately before starting Vault.

**Validation:** Full `make deploy` on a reinstalled VM, `failed=0`.

**Status:** Fixed (2026-11-24).

---

### 36. Fresh install: auditd rule load fails on a missing watched directory

**Symptoms:** `augenrules --load` failed: "Error sending add rule data
request (No such file or directory)".

**Root Cause:** A `-w /etc/vault-ssh-helper.d` watch is loaded by the
auditd role (Phase 2 Tier 1), but that directory is created later by the
auth role (Tier 2). Older hosts had it from earlier runs.

**Fix:** A Phase 2 pre-task stats every `dir:` in `auditd_rules` and
creates only the missing ones (0755 root:root). Existing directories are
never touched.

**Validation:** Full `make deploy` on a reinstalled VM; `ansible-lint`
production profile.

**Status:** Fixed (2026-11-24).

---

### 37. `nginx -t` fails under the confined admin (`sysadm_t`)

**Symptoms:** `nginx: [emerg] bind() to 0.0.0.0:80 failed (13:
Permission denied)` when the config test runs through Ansible become on
a hardened host.

**Root Cause:** `nginx -t` test-binds every listen socket. Run as
`sysadm_t` (staff_u admin via `sudo -r sysadm_r`), the bind is denied by
SELinux. The stock Fedora `nginx.conf` also carried a `listen 80` server.

**Fix:** Project-owned `nginx.conf` (no :80 server) and the reload
handler validates with
`systemd-run --wait --pipe --collect /usr/sbin/nginx -t`, which runs
nginx in its normal `httpd_t` domain.

**Status:** Resolved -- 2026-11-25 -- passed post-redeploy
validation.

---

### 38. DNS-over-TLS silently inactive (dnsconfd config path)

**Symptoms:** dnsconfd pushed `dns+udp://<DHCP resolver>` forwarders;
no DoT despite a complete `static_servers` list.

**Root Cause:** The role wrote `/etc/dnsconfd/dnsconfd.conf`; the
dnsconfd package reads `/etc/dnsconfd.conf` (empty package default).

**Fix:** Render to `dns_dnsconfd_config_file` (`/etc/dnsconfd.conf`) and
remove the stale directory. The verification role now asserts the
forwarders are `dns+tls` only.

**Follow-on finding:** because the file had never been read, it had never
been validated either. Once loaded, `syslog_log: yes` crashed dnsconfd at
start-up (`AttributeError: 'bool' object has no attribute 'startswith'`):
`syslog_log` takes a destination string (`unix:/dev/log`), not a boolean.
The template now uses `journal_log: yes`.

**Status:** Resolved -- 2026-11-25 -- passed post-redeploy
validation.

### 39. systemd `NoNewPrivileges` breaks SELinux domain transitions

**Symptoms:** After adding sandboxing drop-ins, dnsconfd failed with
`Permission denied: '/run/dnsconfd/unbound.conf'` and unbound with
`no search permission ... /var/lib/unbound/root.key`, although file
ownership and labels were correct.

**Root Cause:** With `NoNewPrivileges=yes`, the kernel only allows the
exec-time SELinux transition (`init_t` -> `dnsconfd_t` / `named_t` /
`httpd_t`) if the policy grants `nnp_transition`. The Fedora policy does
not for these domains, so the daemons ran in the wrong domain and were
denied access to their own files.

**Fix:** The nginx, unbound and dnsconfd drop-ins omit
`NoNewPrivileges` (documented in the templates); every other directive
stays. `vault`/`vault-agent` keep it -- the custom `vault_t` policy
handles the transition.

**Related:** `CapabilityBoundingSet=` (empty) on vault-agent made exec
fail ("Failed to execute /usr/bin/vault: Operation not permitted")
because the RPM installs `/usr/bin/vault` with the file capability
`cap_ipc_lock+ep`. The bounding set is `CAP_IPC_LOCK`, matching
`vault.service`.

**Status:** Resolved -- 2026-11-25 -- passed post-redeploy validation.

---

### 40. AppRole `secret_id` TTL silently capped at 32 days

**Symptoms:** `secret_id_ttl 2160h` on the role, but each new
`secret_id` expired after 32 days, which would trigger the 30-day rotation
threshold after two days.

**Root Cause:** The `approle` auth mount inherits Vault's default max
lease TTL (768h), which caps `secret_id_ttl`.

**Fix:** Tune `sys/auth/approle/tune` `max_lease_ttl` to
`vault_approle_secret_id_ttl`. A first deploy still creates one capped
`secret_id` (the mount is tuned just after) and rotates it once.

**Status:** Resolved -- 2026-11-25 -- passed post-redeploy validation.
Rotation exercised end to end 2026-11-26 (`make vault-rotate-secret-id`):
the capped secret_id (expiry 2026-12-27) was replaced by one expiring
2027-02-24 (the full 90 days), and the superseded accessor was
destroyed. The old secret_id is rejected (`invalid role or secret ID`),
the new one authenticates, the agent re-authenticated after the
restart, and certificate renewal continued (client cert re-issued,
browsers re-synced, Nginx login OK).

---

### 41. Vault audit-log rotation never worked (logrotate-vault not loaded)

**Symptoms:** Found in the post-reboot log sweep: `logrotate_t` denied
`getattr` on `/var/log/vault/audit.log` (`vault_log_t`). The daily
`logrotate.service` run would fail and the file-audit log would grow
without bound. It never showed up earlier because the logrotate timer
(00:20) never fired during a deploy session.

**Root Cause:** `logrotate-vault.te` was copied to
`/opt/vault/selinux` but never compiled or loaded. The policy handler
built `vault.pp` only, and the "is the module loaded" check looked for
`vault` only. Version 1.0 of the module also granted only read-side
access.

**Fix:** The handler builds and loads both modules, and the loaded
check requires `logrotate-vault` too, so existing hosts get it on the
next run. Module 1.1 adds directory `write`/`add_name`/`remove_name`
and file `setattr`/`ioctl`. That set was captured from two forced
rotations (copytruncate, rename, delaycompress gzip) in a short
permissive `logrotate_t` window, with permissive mode removed straight
afterwards.

**Status:** Resolved -- 2026-11-25 -- module loaded; two forced rotations in
the real `logrotate_t` domain succeeded (`audit.log.1`, `.2.gz`) with
no AVCs. The first scheduled run is the next 00:20 timer.

---

### 42. Vault cluster listener bind on 8203 denied

**Symptoms:** On every start: `error starting listener: listen tcp
127.0.0.1:8203: bind: permission denied` and an AVC (`vault_t` ->
`unreserved_port_t`).

**Root Cause:** Vault opens a cluster listener at port+1 for **every**
`tcp` listener. The 8202 Nginx mTLS listener therefore also binds 8203,
even on a single-node Raft cluster. Only 8200-8202 were labeled
`vault_cluster_port_t`.

**Fix:** `vault_selinux_ports` (8200, 8201, the proxy listener port and
that port + 1) is labeled with `community.general.seport` right after
the policy module loads, still before Vault's first start. The
hand-rolled `semanage` calls in the handler were removed; they only ran
when the module was first compiled.

**Status:** Resolved -- 2026-11-25 -- after reboot Vault logs `serving cluster
requests ... 127.0.0.1:8203`, with no bind ERROR and no AVC.

---

### 43. Agent-rendered cert/key bundles survived reboots (tmpfiles `e`)

**Symptoms:** At each boot `systemd-tmpfiles` logged
`'/opt/vault/agent-run/*-combined.tmp' already exists and is not a
directory`. The files, which are Agent-rendered certificate and private
key bundles, stayed on disk across reboots.

**Root Cause:** `/etc/tmpfiles.d/vault-run.conf` used `e` for the
`*.tmp` globs. `e` only adjusts directories, so the intended "clean
transient vault secrets on boot" never happened.

**Fix:** `r` (remove at boot) for `{{ vault_run_dir }}/*.tmp` and
`{{ vault_agent_run_dir }}/*.tmp`. vault-agent re-renders the bundles
when it starts.

**Status:** Resolved -- 2026-11-25 -- reboot removed the 15:12 bundles,
vault-agent re-rendered them at boot, and no tmpfiles warning was
logged.

---

### 44. `crypto_policies` NO-SHA1 broke the VS Code repo key

**Symptoms:** fapolicyd (rpmdb backend) and `rpm -qi code` logged
`Certificate EB3E94ADBE1229CF invalid: policy violation ... SHA1 is not
considered secure`. `rpmkeys --checksig` rejected every `code` RPM, so
`dnf upgrade code` would fail its GPG check.

**Root Cause:** Microsoft's signing key (`BC528686...EB3E94ADBE1229CF`)
carries only a SHA-1 key binding signature, which NO-SHA1 rejects.
NO-SHA1 also did **not** remove the `hmac-sha1` / `hmac-sha1-etm` SSH
MACs, the goal the inventory comment gave for it.

**Fix:** A custom sub-policy, `NO-SHA1-MAC` (`mac = -HMAC-SHA1`),
installed by a `site.yml` pre-task before the crypto_policies role runs.
The policy is now `DEFAULT:NO-SHA1-MAC`. Tested on the VM:
`rpmkeys --checksig` reports `OK` for `code`, and `sshd -T` no longer
lists any SHA-1 MAC. The verification role now asserts
`ssh_sha1_macs=0`. Retry the stock NO-SHA1 once the vendor re-signs
its key with SHA-256.

**Status:** Resolved -- 2026-11-25 -- `DEFAULT:NO-SHA1-MAC` active after
reboot; no rpm signature errors; verification asserts
`ssh_sha1_macs=0`.

---

### 45. Post-reboot sweep: accepted residual messages

Reviewed in the 2026-11-25 post-reboot sweep and accepted as is, with
no project change:

- **Vault syslog audit records over ~2 KB are split** into consecutive
  journal entries, so the fragments are not valid JSON. journald itself
  stores 5000-byte syslog messages intact (tested), so the split
  happens in Vault's syslog writer, and the device has no size option.
  The **file** audit device (`/var/log/vault/audit.log`) holds the
  complete record and is the canonical source. The syslog device is an
  independent second stream: Vault keeps serving requests if one device
  fails. Reassemble fragments by order and PID if SIEM forwarding is
  added (backlog P25).
- **NetworkManager** `DNS plugin did not become ready again` at boot
  is a startup race with dnsconfd. Resolution and DNSSEC are correct
  once boot completes. The `org.freedesktop.resolve1` activation
  failure is expected, since systemd-resolved is intentionally off.
- **chrony** `Could not open keyfile /etc/chrony.keys` comes from the
  vendor template's `keyfile` line. All sources authenticate with NTS.
- **Boot needs a console LUKS passphrase.** The root volume has a
  passphrase keyslot only (no TPM2 token, crypttab `none`), so every
  reboot waits on `systemd-tty-ask-password-agent` at tty1. One sweep
  boot spent 4 min 44 s in the initrd waiting for it. This is by design
  today; unattended reboots would need `systemd-cryptenroll --tpm2-device`
  (customer decision, not part of this project).

---

### 46. New USBGuard / logind / staff_t AVC variants after reboot

**Symptoms:** The post-reboot sweep showed `usbguard_t` -> `xdm_t`
`connectto` on `/run/systemd/userdb/org.gnome.DisplayManager`,
`systemd_logind_t` -> `usbguard_tmpfs_t` dir `open` (`/dev/shm/qb-*`),
and `staff_t` -> `user_tmp_t` chr_file `setattr` at each admin login.

**Root Cause:** The existing project modules covered earlier variants
only. GDM now serves its own userdb varlink socket, which USBGuard
queries to resolve `IPCAllowedUsers` names; logind now opens, not just
stats, the libqb IPC directory; and the confined admin's
`systemd --user` manager chmods its `inaccessible/chr` placeholder.
gnome-settings-daemon's `Error appending USBGuard rule: Not authorized`
is the project's IPC ACL working as intended, not a defect.

**Fix:** `usbguard-gdm` 1.1.0 (connectto `xdm_t`), `logind-usbguard`
1.2.0 (`open`/`search`), and a new `staff-systemd-user` 1.0.0 (setattr
on the user's own `user_tmp_t` nodes). All are built by the auth role's
generic policy handler. `staff-systemd-user` also carries two
`dontaudit` rules that the fixed AVC check (#48) surfaced: an optional
`/dev/urandom` write-back by `systemd-creds` (sysadm_t, during the
TPM2+age token decrypt) and a pipe that `systemd-tmpfiles` inherits
from the staff_t SSH session.

**Status:** Resolved -- 2026-11-25 -- the reboot after loading the modules
showed none of these denials; 0 AVCs in the final `make validate`.

---

### 47. Vault Agent split scripts: awk `ioctl` AVCs

**Symptoms:** After #43 (bundles now removed at boot), every boot
logged `vault_t` `ioctl` denials from `awk` on
`/opt/vault/agent-run/*-combined.tmp` (`vault_sys_content_t`) and on the
`*.new` cert and key files in `/etc/vault.d/certs` (`vault_conf_t`) and
`/etc/nginx/certs` (`httpd_config_t`). The same denials occur at each
cert rotation.

**Root Cause:** The Agent's cert-split scripts run `awk`, which probes
`isatty()` (ioctl `TCGETS`) on its files. The reads and writes succeed;
only the probe is denied.

**Fix:** `vault.te` 1.5.0 adds
`dontaudit vault_t { vault_sys_content_t vault_conf_t httpd_config_t }:file ioctl;`.
This grants nothing and only silences the probe.

**Status:** Resolved -- 2026-11-25 -- forced Agent re-render (bundles removed,
agent restarted) re-ran the split scripts with 0 AVCs.

---

### 48. Verification AVC check always reported 0 (ausearch read stdin)

**Symptoms:** `make verify` printed `PASS: 0 AVC denial(s) since boot`
on a boot that `ausearch` run interactively showed had 25 denials.

**Root Cause:** When stdin is not a terminal, `ausearch` reads events
from **stdin** instead of the audit logs. Ansible hands every module a
stdin pipe, so the check parsed an empty stream. The same check also
hid a Phase 0 defect: the raw task that fixes `/root/.ansible/tmp` ran
plain `sudo chmod`/`restorecon`, which stays in `staff_t` for the
confined admin and was denied on every run (masked by `|| true`).

**Fix:** `ausearch --input-logs` in the verification role, which now
also lists the distinct denials when the count is non-zero. The Phase 0
raw task uses `sudo -r sysadm_r -t sysadm_t` when the login is
`staff_r`, the same pattern as the Makefile's `security-test` target.

**Status:** Resolved -- 2026-11-25 -- the check reported the real count (WARN,
28, itemized), then 0 AVCs across the final `make validate`
(verify, security tests, full playbook run).

---

### 49. GDM greeter started a full desktop without a password (regression)

**Symptoms:** After the LUKS passphrase, the console went straight to a
GNOME desktop (Firefox restored its last tabs) with no login prompt.
`loginctl` showed only the `gdm-greeter` session on seat0, yet that
user ran `gnome-session-service --session=gnome` and
`gnome-shell --mode=user`: a full, unconfined desktop as the greeter
account. Found 2026-11-25 by the customer after the post-reboot work.

**Root Cause:** The new CIS session task (`roles/common/tasks/session.yml`,
part of this unreleased batch) used `lineinfile ... create: true` on
`/etc/dconf/profile/gdm`. Fedora ships that profile at
`/usr/share/dconf/profile/gdm`, and dconf reads `/etc` first, so the
two-line project file shadowed the vendor profile. That dropped
`file-db:/usr/share/gdm/greeter-dconf-defaults`, which puts the greeter
in login-screen mode.

**Fix:** The task no longer touches the GDM profile. It removes the
partial file only if its content is exactly what the earlier task
wrote, and writes a complete profile (including the `file-db` line)
only on systems without a vendor profile. A new hard verification
assertion fails if any `gnome-shell --mode=user` runs as the greeter
user or `/etc/dconf/profile/gdm` lacks `greeter-dconf-defaults`. That
assertion failed against the broken state before the fix was deployed.

**Status:** Resolved -- 2026-11-25 -- partial profile removed; after a
GDM restart the greeter runs `gnome-shell --mode=gdm` and the console
shows the login screen; `make validate` passed with the new assertion
(verify `ok=116 failed=0`, 13/13, 5/5, idempotency `changed=28`).

---

### 50. Browser client certificates: Firefox first run and renewal gap

**Symptoms:** On a freshly installed host, Vault TLS-certificate login
fails in Firefox although the certificate is valid (it works with
`curl` and in Chrome).

**Root Cause:** (1) The playbook imports the Vault Agent client
certificate into a Firefox profile only if one already exists. A user
who opens Firefox for the first time after the deploy gets a new
profile without the certificate. (2) The Agent renews the certificate
(72h TTL) by rewriting `/etc/vault.d/certs/client.crt`, but nothing
re-imports it into the browser databases. The browser copies are
refreshed only on playbook runs, so they expire about 72h after the
last run.

**Fix:** `vault-browser-cert-sync` (root oneshot, templated) imports the
current client certificate into `~/.pki/nssdb` and every Firefox
profile of `vault_browser_cert_sync_users`. It is triggered by a
`.path` unit on `client.crt` (every Agent renewal), a timer (2 min after
boot, then every 15 min, which picks up Firefox profiles created later),
and the playbook's Phase 3, which runs after fapolicyd trusts the
script. It compares serials and imports only when they differ, deletes
the old certificate together with its private key, and wraps every NSS
call in a timeout instead of killing browsers. It replaces the inline
tasks that `pkill`ed Chrome/Firefox and wiped `~/.pki/nssdb` on every
run, which removes 7 always-changed tasks. A verification assertion
requires every browser database to hold the current serial.

**Status:** Resolved -- 2026-11-25 -- the sync auto-imported into a
Firefox profile created after the deploy. A forced Agent renewal
(serial `3699D448...` to `0E5423A4...`) updated Chrome and Firefox via
the `.path` unit with no playbook run, leaving one private key per
database. Final `make validate`: verify `ok=120 failed=0` (new
assertion included), 13/13, 5/5, idempotency `changed=21` (ceiling
24), 0 AVCs.

---

### 51. AppRole `secret_id` rotation requires an Ansible run

**Symptoms:** none yet. This is a latent outage. If nobody runs
`make deploy` before the 90-day `secret_id` expires, Vault Agent fails
its next 4-hourly re-authentication. Every Agent-renewed certificate
(Vault TLS, Nginx, browser client cert) then stops renewing, and they
expire within hours to 3 days.

**Root Cause:** By design, Ansible is the only rotator (HashiCorp's
"trusted orchestrator" pattern): rotation runs when fewer than 30 days
remain, or on demand. The only warning was a WARN in `make verify`,
which nobody sees unless they run it.

**Fix (mitigation):** Every run records the active expiry in
`/etc/vault-agent.d/approle-secret-id.expires` (Vault's absolute
`expiration_time`, which keeps the task idempotent).
`vault-approle-expiry-check.timer` (daily, `Persistent=true`) logs
`auth.warning` and writes a login banner (`/etc/motd.d/50-vault-approle`)
below 14 days, and fails the unit below 7 days. It needs no Vault
token. Verification asserts that the recorded expiry matches Vault,
that exactly one secret_id exists, and that the timer is active.
Autonomous on-host rotation was considered and not chosen, because it
would add a second credential path.

**Status:** Resolved (mitigated) -- 2026-11-26 -- timer active, and
the recorded expiry (2027-02-24) matches Vault. The normal run logs OK
(89 days); simulated <14 days gives `auth.warning` and the login banner;
simulated <7 days fails the unit; the next normal run clears both.
`make validate`: verify `ok=122 failed=0`, 13/13, 5/5, idempotency
`changed=21`, 0 AVCs, and no rotation while the secret_id is healthy.

---

### 52. VaultPass: one shared writable folder, no per-user space

**Symptoms:** VaultPass showed a single folder, `default/`, and every
VaultPass user could create, change or delete anything in it. A
user-created entry did not appear where the user looked: it was named
after the site, `vault.internal`, not the title, and the Vault UI hid
the store root.

**Root Cause:** One cert role (`workstation-client`, admin CN only) and
one policy (`vaultpass`: CRUD on `secret/vaultPass/*`). VaultPass lists
whatever folders exist under its KV store path and offers them in its
"Add key" dropdown. Only `default/` existed. The placeholder
`default/.init` was also a URL regex (`.init` matches any URL
containing `<char>init`), and every deploy rewrote it, adding a KV
version each time.

**Fix:** `vault_vaultpass_users` (inventory) drives everything:

- a personal read/write folder `secret/vaultPass/<user>/` per user;
- the policy `vaultpass-user-<user>`;
- a cert role `vaultpass-<user>` accepting only CN `<user> - VaultPass`;
- for users with a Linux account, an Agent-issued client cert synced
  into their browsers.

Shared `default/` is read-only for VaultPass users and curated by Vault
admins. `workstation-client` and `.init` are removed. Placeholders
(`^vaultpass-placeholder$`, never matches a URL) are created only when
missing. Removing a user deletes their role and policy, never their
data. Verification checks the admin's real certificate through Nginx:
own folder read/write, `default/` read-only, other folders denied.

**Status:** Resolved -- 2026-11-26 -- `vaultpass-jayissi` maps CN
`jayissi - VaultPass` to `vaultpass` + `vaultpass-user-jayissi`. With the
user's certificate through Nginx, the own folder allows full read/write;
on `default/` reads succeed and create/update/delete return 403; the
`secret/` root and `grub` return 403. A simulated second user `vptest`
was isolated in both directions. Removing it deleted its role and
policy and kept its data. The two user test entries were moved from
`default/` to `jayissi/`, and `workstation-client` and `.init` were
removed. `make validate`: verify `ok=125 failed=0`, 13/13, 5/5,
idempotency `changed=21`, 0 AVCs.

---

### 53. Every deploy minted a new admin token and never revoked the old

**Symptoms:** `secret/tokens/admin` was at version 25, and Vault held 27
live `admin-daily` tokens (`vault-admin-full`) and 27
`monitoring-readonly` tokens. Each stayed valid for up to 32 days, so
any copy that ever leaked kept working.

**Root Cause:** `pki_engine.yml` called `auth/token/create` (`ttl: 0`,
which means the 32-day default maximum) on every run, and
`backup_secrets.yml` overwrote the KV copy. Nothing revoked the
previous token.

**Fix:** `_daily_token.yml` keeps one **periodic** token per purpose
(`vault_daily_tokens`, `vault_daily_token_period` 768h):

- it looks up the stored token and renews it while it is valid and
  correctly scoped;
- otherwise it creates a replacement, stores it (with its accessor) and
  revokes the old one;
- every run also revokes any other `admin-daily` / `monitoring-readonly`
  token, which cleared the backlog.

A periodic token has no maximum lifetime: each renewal (deploy, or an
active UI session) resets the period. Verification asserts exactly one
of each and that the stored tokens are periodic.

**Status:** Resolved -- 2026-11-26 -- the first run revoked 52 stray
daily tokens and replaced the two current ones with periodic tokens
(32-day period). Afterwards Vault held exactly one `admin-daily` and one
`monitoring-readonly` token, and both stored tokens authenticate. A full
re-run (`make validate`) left the KV versions unchanged (26) with no new
tokens.

---

### 54. TLS copies in KV: stale server certificate and private key

**Symptoms:** `secret/tls/server` held a Vault server certificate, the
intermediate and its **private key**. It was written once at the first
deploy and never updated, while Vault Agent re-issued the live
certificate. `secret/tls/root-ca` held the Root CA only. Nginx and
other certificates had no copy.

**Fix:** public material only, rewritten only when it changes:

- `secret/tls/ca`: `root_ca`, `intermediate_ca`, `ca_chain`
  (intermediate + root);
- `secret/tls/vault` and `secret/tls/nginx`: `certificate` and
  `ca_chain`.

The legacy `tls/root-ca` and `tls/server` were deleted, taking the
stale private key with them. The PKI engine remains the authoritative
source (`/v1/pki/ca/pem`, `/v1/pki_int/ca_chain`, no token needed).
Leaf private keys are never copied into KV.

**Status:** Resolved -- 2026-11-26 -- `tls/ca` (`root_ca`,
`intermediate_ca`, `ca_chain`), `tls/vault` and `tls/nginx`
(`certificate`, `ca_chain`) were written. Their certificates match the
live Vault and Nginx certificates byte for byte, and no private keys
are stored. `tls/root-ca` and `tls/server` were deleted. A re-run left
all three at version 1 (no rewrite when unchanged).

---

### 55. VaultPass placeholders kept in folders that have entries

**Symptoms:** `^vaultpass-placeholder$` stayed in `jayissi/` after it
held real entries, which looked like leftover test data.

**Root Cause:** A KV folder exists only while it holds a key. The
placeholder is needed so an *empty* folder still appears in VaultPass,
where a new user saves their first entry. Nothing removed it once real
entries existed.

**Fix:** each run lists every VaultPass folder. It creates the
placeholder only in empty folders and removes it from folders that hold
real entries. Verification asserts this per folder. If a user deletes
their last entry, the folder disappears until the next deploy recreates
the placeholder; saving into it still works, because KV creates paths
on write.

**Status:** Resolved -- 2026-11-26 -- the placeholder was removed from
`jayissi/` (holds `vault.internal`) and kept in the empty `default/`.
Verification asserts the rule per folder, and `make validate` passed:
verify `ok=127 failed=0`, 13/13, 5/5, idempotency `changed=21`, 0 AVCs.

---

### 56. Read-only token could not list secrets but could read the admin token

**Symptoms:** The `monitoring-readonly` token got 403 listing `secret/`,
yet got **200 reading `secret/tokens/admin`**. Anyone holding the
"read-only" token could take the admin token, a privilege escalation.

**Root Cause:** `vault-admin-readonly` granted `read`/`list` on
`secret/data/*`. On KV v2, listing and version metadata live under
`secret/metadata/*`, so the `list` never applied, while `read` on
`secret/data/*` also covered `secret/data/tokens/*`.

**Fix:** The policy now grants `secret/data/*` read and
`secret/metadata/*` read/list, with an explicit **deny** on
`secret/data/tokens/*` and `secret/metadata/tokens/*`. Verification
uses the stored read-only token to check: list `secret/` = 200, read
`tls/ca` = 200, read `tokens/admin` = 403, write = 403. Before the
policy was deployed, that assertion failed on the old policy, as it
should.

**Status:** Resolved -- 2026-11-26 -- before the fix: list `secret/` =
403, read `tokens/admin` = **200**. After: list `secret/` = 200, read
`tls/ca` = 200, read `tokens/admin` = 403, list `tokens/` = 403,
write = 403. `make validate`: verify `ok=127 failed=0`, 13/13, 5/5,
idempotency `changed=21`, 0 AVCs.

---

## Backlog / Future Work

Deferred items tracked for future implementation. These are not
blocking the current plan and are listed in rough priority order.

### Backlog Status Summary

Status markers follow the issue-tracker convention used throughout this
file: `Resolved — YYYY-MM-DD` is the date the item **passed
post-redeploy validation** (`make deploy` + `make validate`), not the
date code was written. `In progress` means implemented and passing
`make ci`, awaiting that validation. `Deferred` items carry the reason.

**Validation record (2026-11-25):** fresh reinstall of `testfedora`,
`make deploy` `failed=0`, then `make validate`: verify `ok=114
failed=0` (all outcome assertions), security-test 13/13, bastion-test
5/5, idempotency re-run `changed=28` (baseline 30, `failed=0`).

**Post-reboot record (2026-11-25):** two reboots plus log sweeps
(dmesg, journal, audit/AVC, failed units); issues #41-#48 fixed and
redeployed. Final `make validate`: verify `ok=115 failed=0`,
security-test 13/13, bastion-test 5/5, idempotency `changed=28`, and
0 AVCs across the whole run.

| Item | Title                                         | Status   | Date       | Reference                 |
|------|-----------------------------------------------|----------|------------|---------------------------|
| P10  | Unrestricted inbound DoT 853 rule             | Resolved | 2026-11-25 | CHANGELOG [Unreleased]    |
| P12  | DNS local-data TTL                            | Resolved | 2026-11-25 | CHANGELOG [Unreleased]    |
| P14  | `.local` → `.internal`                        | Resolved | 2026-11-25 | ADR-0008                  |
| P15  | Remove Google DNS upstreams                   | Resolved | 2026-11-25 | CHANGELOG [Unreleased]    |
| P16  | Pin DoT egress to approved upstreams          | Resolved | 2026-11-25 | firewalld `dot-egress`    |
| P17  | DNSSEC operational verification               | Resolved | 2026-11-25 | verification/outcomes.yml |
| P18  | DNS security regression suite                 | Partial  | 2026-11-25 | partial (see item)        |
| P19  | QNAME minimisation off in forwarder mode      | Resolved | 2026-11-25 | CHANGELOG [Unreleased]    |
| P20  | DoT fail-closed detection                     | Deferred | 2026-11-25 | needs design              |
| P21  | nsswitch `[NOTFOUND=continue]`                | Resolved | 2026-11-25 | CHANGELOG [Unreleased]    |
| P22  | Core blocklist alongside RPZ                  | Resolved | 2026-11-25 | CHANGELOG [Unreleased]    |
| P23  | systemd sandboxing                            | Resolved | 2026-11-25 | CHANGELOG [Unreleased]    |
| P24  | `ca_path` instead of `validate_certs: false`  | Resolved | 2026-11-25 | CHANGELOG [Unreleased]    |
| P25  | Vault audit forwarding to SIEM                | Deferred | 2026-11-25 | needs SIEM target         |
| P26  | SSH gateway bastion mTLS                      | Resolved | 2026-11-25 | OPERATIONS (bastion)      |
| P27  | SSH gateway method restriction                | Resolved | 2026-11-25 | CHANGELOG [Unreleased]    |
| P28  | 8443 default-deny (adapted)                   | Resolved | 2026-11-25 | see item                  |
| P29  | CSP report endpoint                           | Resolved | 2026-11-25 | CHANGELOG [Unreleased]    |
| P30  | Fedora lifecycle / RHEL evaluation            | Deferred | 2026-11-25 | customer decision         |
| P31  | Structured JSON access logs                   | Resolved | 2026-11-25 | CHANGELOG [Unreleased]    |
| P32  | Cache-Control response headers                | Resolved | 2026-11-25 | CHANGELOG [Unreleased]    |
| —    | AppRole `secret_id` rotation                  | Resolved | 2026-11-25 | OPERATIONS (rotation)     |
| —    | CIS session sub-items (TMOUT, lock, cron, su) | Resolved | 2026-11-25 | CHANGELOG [Unreleased]    |
| —    | Vault telemetry                               | Deferred | 2026-11-25 | not in batch              |
| —    | USBGuard class-based policy                   | Deferred | 2026-11-25 | not in batch              |
| —    | Duplicate sudo NOPASSWD line                  | Deferred | 2026-11-25 | base image; see item      |

### Active CRL Revocation Checking (`ssl_crl`)

~~The `ssl_crl` directive in `vault-proxy.conf.j2` was commented out
pending dual-CRL fetch implementation, staleness validation, and
fail-closed behavior.~~

**Status:** Resolved — `ssl_crl` is now active with dual-CRL fetch
(Intermediate + Root CA), `nextUpdate` staleness check with
fail-closed behavior, CRL backup before replacement, and automatic
rollback on `nginx -t` failure. See Phase A implementation and
[OPERATIONS.md](OPERATIONS.md) for the CRL emergency revocation
procedure.

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

~~Extend Vault Agent's `template` stanza to pre-render a fresh
break-glass SSH certificate to local disk on a cadence inside the 72h
max TTL.~~

**Status:** Implemented — `breakglass-ssh-cert.tpl.j2` Vault Agent
template auto-renews the break-glass SSH certificate to local disk
within its TTL window.

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

**Status (sub-items):** Resolved — 2026-11-25 — passed
post-redeploy validation — shell idle timeout (`common_shell_timeout`,
default **3600 s** -- a variable, not the CIS 900 s), GNOME auto-lock,
GDM banner, `su` via `pam_wheel`, and `cron.allow`/`at.allow` are
implemented. Concurrent session limits and the full framework mapping
remain open.

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

~~Strengthen auto-unseal by binding the age identity credential to
specific boot-chain PCR values
(`systemd-creds encrypt --with-key=tpm2 --tpm2-pcrs=7+11`), not just
TPM chip presence.~~

**Status:** Implemented — `roles/vault/tasks/init.yml` gates
`systemd-creds encrypt` with `--tpm2-pcrs=7+11` when
`_common_secure_boot_enabled` is true. The credential only decrypts
if the system booted with the expected kernel/initrd/bootloader.

**Note:** kernel updates change PCR values, requiring re-sealing
before reboot. `systemd-measure` can pre-calculate expected PCR values
for new UKI images.

### Secure Boot Verification

~~Add a check in the verification role to confirm Secure Boot is
actually enabled.~~

**Status:** Implemented — `roles/common/tasks/preflight.yml` and
`roles/verification/tasks/hardware.yml` now check Secure Boot status
with adaptive `WARN` (non-fatal for VMs / hardware without SB
support).

### USBGuard Class-Based Policy Refinement

Currently whitelists all plugged-in devices at deploy time. Could
restrict to HID-only (keyboard/mouse) and block mass-storage USB class
to prevent BadUSB and data-exfiltration attacks.

**Status:** Deferred — 2026-11-25 — not selected for the 2026-11-25
batch.

### Vault Telemetry

Enable the `telemetry` stanza in `vault.hcl` for
Prometheus-compatible metrics. Zero-cost to enable (no scraper
required), provides future observability capability per HashiCorp's
hardening checklist.

**Status:** Deferred — 2026-11-25 — not selected for the 2026-11-25
batch.

### AIDE `/boot/efi` SELinux `dosfs_t` Denial

~~`aide_t` lacks `getattr` permission on the `vfat` filesystem class,
causing AVC denials when AIDE scans `/boot/efi`.~~

**Status:** Fixed — `aide-efi.te` SELinux module created and deployed,
granting `aide_t` the minimal `getattr` permission on `dosfs_t`.

### fapolicyd GDM Socket Denial

~~During deploy-time trust-database rebuilds, fapolicyd briefly denies
GDM's access to a Unix socket.~~

**Status:** Fixed — `fapolicyd-gdm.te` v1.1.0 handles both
`sock_file write` and `unix_stream_socket connectto` permissions.

### AppRole `secret_id` Rotation

`secret_id_num_uses: 0` (unlimited) and `secret_id_ttl: 0` (never
expires) is weaker than HashiCorp's recommended posture. Mitigated by
TPM2-bound ciphertext, short-lived derived tokens (1h/4h), and
least-privilege policies. Future improvement: extend
`vault-agent-secret.service` to call the Vault API for a fresh
`secret_id` on each run rather than re-decrypting static ciphertext.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — `secret_id_ttl: 2160h`, loopback-bound
(`secret_id_bound_cidrs` / `token_bound_cidrs`), automatic rotation
below 30 days, `make vault-rotate-secret-id`; `make verify` warns below
14 days.

### Duplicate sudo NOPASSWD Line

Both the base image and `00-hardening` drop-in contain a sudo
`NOPASSWD` line for the admin user. Identified during E2E validation
but not yet consolidated. Functionally harmless (sudo processes both,
second is redundant) but should be deduplicated.

**Status:** Deferred — 2026-11-25 — the duplicate comes from the base
image, and Ansible's `sudo -n` depends on the repo's NOPASSWD rule;
removing NOPASSWD for humans needs a become-password design.

### Vendor-Role Non-Idempotency

`linux-system-roles.tlog`, `linux-system-roles.tuned`, and
`linux-system-roles.fapolicyd` have unconditional `changed_when: true`
tasks. Confirmed-correct end-state via direct verification. Not a bug
to patch — the `collections/` directory is vendored and not modified
per project convention.

**Baseline (re-measured 2026-11-25 on a freshly redeployed VM):**
`changed=21` on an idempotent re-run (`make idempotency`, ceiling
`VALIDATE_MAX_CHANGED=24`). Breakdown: vendored tuned (3), tlog (2) and
fapolicyd (5) roles; fapolicyd cache tuning (2); authselect re-select
and nsswitch override (2, see #19); Vault Agent service enable (1);
proxy client-CA chain rebuild (1); NetworkManager reload (1);
`LogDenied=unicast` re-applied after the firewall role's
`previous: replaced` reset (1), plus loop items. It was 28 until the
inline VaultPass NSS re-import (7 always-changed tasks) was replaced by
`vault-browser-cert-sync` (#50) and the Firefox PKCS#11 registration
stopped reporting changed on failure. The old figure of 18 predates
the validation and session controls.

### `crypto_policies` FUTURE Profile Tested and Reverted

`crypto_policies` FUTURE was tested and reverted to DEFAULT. Root
cause: RSA 2048-bit EE certificates on `releases.hashicorp.com` and
`packages.microsoft.com` are rejected by the FUTURE profile.
vault-ssh-helper download uses `validate_certs: false` + pinned
SHA-256 checksum as a compensating control. The `rpm_key` module has
no `validate_certs` option for the Microsoft GPG key case, making
FUTURE policy impractical without broader CDN/repository changes.

### Customer Operational Review — Priority Backlog

The following items were identified during the customer operational
review and are pending engineering discussion. Listed in recommended
priority order (highest risk / most blocking first).

**Priority 1 — Vault backup and disaster recovery (§2.b):**
No automated backup exists today. Define Raft snapshot frequency
(`vault operator raft snapshot save`), retention policy, encrypted
off-site storage, restoration procedure, and RPO/RTO targets. Decide
whether backup encryption should use the same age+TPM2 pattern as
unseal keys or a separate key hierarchy (same TPM2 binding creates a
single point of failure — lose the TPM chip, lose both unseal keys
and backups). Document a TPM2 disaster recovery procedure: steps for
recovering Vault secrets when the original hardware is unavailable,
using only the passphrase-based `.age.pass` backup and a Raft
snapshot.

**Priority 2 — Vault version updates and patch management (§2.c):**
Vault is installed via direct binary download with SHA-256 checksum
verification, not through the OS package manager. Updates are not
automatic — `vault_version` must be changed and the playbook re-run.
Define the update process: staging environment testing, mandatory
pre-upgrade Raft snapshot, rollback procedure (downgrade can corrupt
Raft storage if a schema migration occurred), and criteria for
distinguishing security patches from feature releases. Determine
whether updates should remain manually approved or follow a
controlled automation path.

**Priority 3 — Firewall, SELinux, fapolicyd, and Nginx compatibility
for LAN access (§1.b):**
If DNS and Vault are exposed to the LAN, scope the security control
changes required: firewall zone/service rules, SELinux port contexts
and new policy modules, fapolicyd trust entries for any new binaries,
Nginx path allowlist expansion (currently only `/v1/ssh-otp/creds/`
and `/v1/ssh-ca/sign/`), and systemd sandboxing adjustments. Key
architectural decision: should Vault's listener move to `0.0.0.0:8200`
(full API surface to LAN, relying on Vault auth/authz alone), or
should Nginx remain the LAN-facing ingress with broader path
allowlists (defense-in-depth, API surface reduction)?

**Priority 4 — VaultPass extension updates and browser security
(§2.d):**
VaultPass is a third-party browser extension, not maintained by
HashiCorp. **Update:** Chrome extensions were removed entirely due to
Manifest V2 deprecation (Chrome 139+ removed MV2 support; see issue
issue 32). VaultPass and uBlock Origin are now Firefox-only. Updates are
handled by Firefox's extension auto-update mechanism (AMO), not by this
project. Define: private/incognito mode permission policy (requires
explicit "allow in private windows"), centralized version control via
Firefox enterprise policies (partially in place for DoH lockdown),
extension supply-chain risk assessment (compromised update could
exfiltrate Vault tokens), and compatibility testing process for new
extension versions against the deployed Vault version.

**Priority 5 — Vault migration strategy (§2.a):**
Less urgent if Priority 1 (backup/recovery) is solid, since migration
is effectively "restore to different hardware." Key constraint:
TPM2-bound unseal keys are tied to the original machine's TPM chip.
Migration to new hardware requires the passphrase-based `.age.pass`
backup. Scope: Raft data directory, Vault configuration, TLS
certificates, SELinux policy modules, AppRole credentials, and DNS
re-binding.

**Priority 6 — Monitoring and alerting:**
No monitoring exists beyond systemd service restart and journald
logging. Vault audit devices are configured (file + syslog) but there
is no alerting on authentication failures, seal events, or service
outages. Define monitoring scope for Vault availability, DNS
availability, certificate expiry, and authentication anomalies.

**Priority 7 — Incident response runbook:**
No documented procedure for compromised credentials. Existing
capabilities: root token rotation (`make vault-rotate-root-token`),
break-glass SSH cert auto-renewal, AppRole secret_id re-provisioning
on restart. Missing: documented procedure for suspected compromise of
unseal keys, root token backup, or Vault Agent tokens.

**Priority 8 — Chrome JSON pretty-print for status.vault.local:**
Chrome lacks a native JSON viewer (unlike Firefox). The
`status.vault.local` health endpoint returns raw JSON which Chrome
displays as plain text with a manual "Pretty-print" checkbox.
Evaluate deploying a Chrome JSON viewer extension (e.g., JSON Viewer,
JSONVue) via enterprise `ExtensionSettings` policy to provide
automatic pretty-printing. Lower priority — Firefox already renders
JSON natively, and Chrome's manual checkbox is functional.

**Priority 9 — VaultPass TLS client certificate auth flow:**
The Nginx re-encryption architecture is now fully implemented: browsers
present their TLS client certificate to Nginx, which validates it and
forwards the URL-encoded cert to Vault via `X-Client-Cert` /
`x_forwarded_for_client_cert_header`. Cert auth works end-to-end
through `https://vault.local` in both Firefox and Chrome.
**Update:** Auto-cert-select is now implemented in both browsers —
Firefox via `security.default_personal_cert = "Select Automatically"`
(locked enterprise policy) and Chrome via `AutoSelectCertificateForUrls`
with issuer filter `O=Local Lab Infrastructure` (see issue #31).
VaultPass credential display is now working: the popup Keys tab displays
matched credentials with copy/fill buttons, and "Add Key" / "Save Key"
work end-to-end. The Vault policy was renamed from `vaultpass-readonly`
to `vaultpass` with full CRUD capabilities (create, read, update,
delete) including `auth/token/revoke-self` for VaultPass logout.
VaultPass token acquisition uses "Get Token from Vault Tab"
(content-script based) as the primary method — requires a Vault UI tab
to be open and authenticated. VaultPass's "Login via Web" button remains
broken on Firefox due to a third-party extension bug (`importScripts is
not defined` in `background.js:2` — Chrome Manifest V3 API not
available in Firefox's Manifest V2 background scripts). This is not a
project infrastructure issue. See [OPERATIONS.md](OPERATIONS.md) for the
complete browser login procedure.

**Priority 10 — Unrestricted DoT port 853 firewall rule:**
The firewall rich rule `port port="853" protocol="tcp" accept` in
`inventory/group_vars/all/main.yml` has no source address filter,
unlike every other rich rule in the list. Unbound only acts as a DoT
*client* (outbound to upstream resolvers), so an unrestricted *inbound*
allow on port 853 is unexpected and should be reviewed in a future
firewall hardening pass. Not related to the Nginx/Vault mTLS plan;
flag separately.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — inbound `853/tcp` accept removed from the rich rules
(`playbooks/site.yml`); DoT is outbound-only (see P16).

**Priority 11 — Logrotate verification for new Nginx log files:**
Phase 3 of the Nginx mTLS plan added per-vhost access logs
(`vault-mtls-access.log`, `ssh-gateway-access.log`) under
`/var/log/nginx/`. Fedora's stock `nginx` RPM ships a default
`/etc/logrotate.d/nginx` that globs `/var/log/nginx/*.log`, which
should automatically cover the new files. Verify on the VM
(`cat /etc/logrotate.d/nginx` and `logrotate -d /etc/logrotate.d/nginx`)
that the glob matches. If it does not glob, add an explicit logrotate
stanza to the proxy role.

**Priority 12 — DNS local-data TTL:**
`local-data` entries in `roles/dns/templates/local-zones.conf.j2` for
`vault.local` and `status.vault.local` rely on Unbound's default TTL
rather than an explicit value. Low priority since the IP (`127.0.0.1`)
never changes, but worth adding an explicit TTL for clarity if this
template is touched again.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — `dns_local_data_ttl: 3600` rendered on every `local-data`
record (per-record `ttl:` override).

**Priority 13 — Evaluate `nginxinc.nginx_core` collection for Nginx
configuration management:**
The official NGINX Ansible collection (`nginxinc.nginx_config`) provides
variable-driven configuration management for TLS, vhosts, upstreams,
rate limiting, and HTTP/2. Not needed today — the project's 4-template,
1-snippet architecture is simpler and more auditable for a
single-workstation deployment — but becomes valuable if the project
scales to multi-host deployments, LAN-facing Nginx exposure
(Priority 3), or team-operated environments where variable interfaces
are more approachable than direct Jinja2 templates. Pin version in
`collections/requirements.yml` when adopting. Custom Vault integration
(cert forwarding, CRL, backend mTLS, SELinux) stays project-owned
regardless.

**Priority 14 — Migrate `.local` to `.internal` namespace:**
RFC 6762 reserves `.local` for multicast DNS (Avahi/Bonjour). The
current `vault.local` and `status.vault.local` hostnames conflict with
this reservation. The nsswitch `hosts:` line has
`mdns_minimal [NOTFOUND=return]` which can terminate resolution before
Unbound is consulted for `.local` names — the `/etc/hosts` entry masks
this but it is fragile. Migrate to `vault.internal` /
`status.vault.internal` using the `.internal` TLD (ICANN special-use
reservation for private networks). Touches: `dns_local_data`,
`dns_local_data_ptr`, `dns_private_domains`, `/etc/hosts` entry,
`vault_local_hostname`, Nginx `server_name`, TLS certificate SANs
(all 3 PKI roles), managed bookmark URLs, VaultPass KV URL patterns,
`proxy_ssl_name`, Vault `api_addr`, and documentation. Remove the
`local-zone: "local." nodefault` workaround in `unbound.conf.j2` after
migration. Identified by two independent architecture reviews.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — migrated to `.internal` with one source of truth in the
inventory ([ADR-0008](decisions/ADR-0008-internal-namespace.md));
`local-zone "local." nodefault` removed.

**Priority 15 — Remove Google DNS from upstream resolvers:**
Google Public DNS (`8.8.8.8`, `8.8.4.4`) provides no malware/phishing
filtering, unlike Quad9 and Cloudflare malware-filter variants. Unbound
does not use a strict primary→fallback ordering — it can select any
configured forwarder based on availability and RTT. A query falling
through to Google silently bypasses the threat-filtering policy enforced
by Quad9 and Cloudflare. Remove Google; retain 4 Quad9 endpoints
(primary, threat intelligence) + 2 Cloudflare malware-filter endpoints
(secondary, equivalent policy). Both apply threat filtering, so
failover does not weaken the security posture.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — upstreams now `dns_dot_upstreams` (Quad9 + Cloudflare
malware-filtering); Google removed.

**Priority 16 — Restrict DoT port 853 firewall rule to approved upstreams:**
The current rich rule `port port="853" protocol="tcp" accept` allows
any process to establish DoT connections to any external server.
Restrict to the specific upstream DoT resolver IPs (Quad9 and
Cloudflare) to prevent rogue applications from exfiltrating DNS queries
via unauthorized DoT tunnels. Supersedes Priority 10 (which flagged the
missing source filter; this item adds the destination filter).

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — firewalld policy `dot-egress` (HOST → ANY) accepts tcp/853
only to `dns_dot_upstreams`, rejects all other 853.

**Priority 17 — DNSSEC operational verification test:**
Add a DNSSEC validation test to `roles/verification/tasks/network.yml`:
`dig @127.0.0.1 dnssec-failed.org` must return SERVFAIL (not a
successful resolution). dnsconfd's upstream README notes that "DNSSEC
validation is turned off to prevent potential problems" — the project's
`zz-module-override.conf` overrides this with
`module-config: "respip validator iterator"`, but runtime verification
is needed to confirm validation is actually active, not merely
configured.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — `roles/verification/tasks/outcomes.yml` asserts
`dnssec-failed.org` → SERVFAIL and `isc.org` → NOERROR + `ad`.

**Priority 18 — DNS security regression test suite:**
Create a dedicated `dns-security-test.yml` playbook or extend the
verification role with automated DNS security assertions. Tests should
cover: normal resolution, DNSSEC valid domain, DNSSEC broken domain
(SERVFAIL), RPZ-blocked domain (NXDOMAIN), internal hostname resolution,
DoT certificate verification, primary upstream unavailable (approved
secondary used), both upstreams unavailable (no insecure fallback),
dnsconfd restart recovery, browser DoH policy enforcement, and
unauthorized outbound port 53 (blocked). Identified by both
architecture reviews as a gap.

**Status:** Resolved (partial) — 2026-11-25 — passed post-redeploy
validation — partially: outcome checks cover normal resolution, DNSSEC
valid/bogus, RPZ and core-blocklist blocking, internal names and
`dns+tls`-only forwarders; upstream-failure scenarios remain open.

**Priority 19 — Disable QNAME minimisation in forwarder mode:**
`qname-minimisation: yes` is enabled in `unbound.conf.j2` but Unbound
operates as a forwarder (all external queries go to dnsconfd-managed
DoT upstreams via forward zones). QNAME minimisation only reduces label
exposure during recursive delegation walks (root → TLD → authoritative);
in forwarding mode the upstream resolver receives the full FQDN
regardless. The on-path segment is already DoT-encrypted. The practical
effect is extra round-trips per cold query with zero privacy benefit
against the party that actually sees the query. Set
`dns_qname_minimisation: false` in defaults. Identified by third
architecture review.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — `dns_qname_minimisation: false`.

**Priority 20 — DoT strict mode total outage on restricted networks:**
When TCP port 853 is blocked by the local network (hotel, corporate
guest VLAN, captive portal), all eight DoT upstream forwarders fail
identically. There is no cleartext fallback — DNS fails closed entirely.
This is the correct security posture on trusted networks, but on
restricted networks it takes the entire workstation offline with no
diagnostic signal. Add a NetworkManager dispatcher or dnsconfd health
probe that detects 853 blockage before locking the configuration. On
failure, fall back to a named plaintext upstream with an explicit audit
log entry so the operator knows degradation occurred. The security
property that matters is knowing when you have degraded; total blackout
without notification is not a security win.

**Status:** Deferred — 2026-11-25 — needs a dispatcher/health-probe
design; tracked for a later batch.

**Priority 21 — Change nsswitch `[NOTFOUND=return]` to `[NOTFOUND=continue]`:**
The nsswitch `hosts:` line
(`files mdns_minimal [NOTFOUND=return] myhostname dns`) terminates
resolution at `mdns_minimal` when Avahi returns NOTFOUND for a `.local`
query. This prevents Unbound from ever seeing `.local` names that only
exist in its `local-data` directives. The `/etc/hosts` entry masks this
for `vault.local`, but any future `.local` service added only to
Unbound would be silently unreachable. Change to `[NOTFOUND=continue]`
in `auth_nsswitch_hosts` so `.local` misses from Avahi fall through to
the `dns` module. The performance cost of falling through on mDNS
misses is negligible. This fix is independently valuable even after
the `.local` → `.internal` migration (Priority 14).

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — `[NOTFOUND=continue]` from the single `auth_nsswitch_hosts`
variable, used by both the dns and auth roles.

**Priority 22 — Keep minimal local-zone blocklist alongside RPZ:**
RPZ and the legacy blocklist timer are mutually exclusive
(`dns_rpz_enabled` disables the blocklist timer). If the RPZ zone
becomes corrupt, the fetch fails on boot before a cached zone exists,
or the `zonefile` is truncated, Unbound may load an empty policy —
leaving the workstation unprotected with no secondary blocklist active.
Keep a minimal high-confidence malware `local-zone` blocklist (even
just a few hundred entries) active at all times via `conf.d/` drop-in,
independent of RPZ state. The overlap is harmless; the loss of blocking
when RPZ fails is not.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — core HaGeZi TIF-mini `local-zone` list now runs alongside
RPZ (`dns_core_blocklist_urls`), de-duplicated, with an empty-download
guard.

**Priority 23 — systemd sandboxing for DNS services:**
Add systemd sandboxing directives to `dnsconfd.service` and
`unbound.service`: `ProtectSystem=strict`, `PrivateTmp=yes`,
`MemoryDenyWriteExecute=yes`, and `IPAddressDeny=any` /
`IPAddressAllow=localhost` for dnsconfd (which only communicates with
Unbound via `unbound-control` on the loopback). SELinux provides
mandatory access control but is coarse-grained and can break on Fedora
major-version upgrades when policy interfaces change. systemd
sandboxing is finer-grained, upgrade-safe, and constrains the daemon's
blast radius independently of the SELinux policy modules. The secureblue
project (a Fedora derivative focused on hardening) uses this approach
for its dnsconfd integration. Requires careful testing for SELinux
interaction — the Vault syslog audit debugging in this session
demonstrated that `PrivateDevices=yes` can cause unexpected failures
when combined with custom SELinux domains.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — sandboxing drop-ins for unbound (`ProtectSystem=full`),
dnsconfd and nginx; hardened vault-agent unit; asserted by the outcome
checks.

**Priority 24 — Convert `validate_certs: false` to `ca_path` in pki_engine.yml:**
All 27 `ansible.builtin.uri` tasks in `roles/vault/tasks/pki_engine.yml`
use `validate_certs: false` because Ansible runs before the system CA
trust store includes the private Root CA. This is a bootstrap ordering
constraint (chicken-and-egg problem): the private CA does not exist in
the system trust store until the playbook creates it, and the `uri` tasks
that create the PKI happen in the same playbook run. The CRL bootstrap
task was already converted to use `ca_path` as a per-task fix. Apply the
same `ca_path` pattern to all 27 `uri` tasks in `pki_engine.yml`,
pointing to the Root CA file on disk (`/etc/vault.d/certs/root.crt`)
which exists after `tls_production.yml` runs. Tasks that execute before
the Root CA is on disk (bootstrap-only, gated by `when` conditions) may
retain `validate_certs: false` with an inline comment documenting the
ordering constraint. No further deep-dive is needed — the pattern is
proven by the CRL bootstrap fix and the approach is well understood.
Identified by CAB reviewer R1 as a production readiness concern.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — all vault-role `uri` tasks validate TLS with `ca_path`
(`_vault_ca_path`: saved bootstrap certificate, then the production Root
CA); proxy, verification and Phase 2 calls use the Root CA.

**Priority 25 — Vault audit remote log forwarding to SIEM:**
HashiCorp recommends at least two audit devices with at least one
forwarding to a remote system. Currently Vault has file + syslog audit
backends, both local. Add centralized SIEM forwarding (e.g., via rsyslog
or a dedicated audit socket backend) for tamper-resistant, queryable
audit trails. CAB reviewer R1 identified this as a production
prerequisite.

**Status:** Deferred — 2026-11-25 — needs a customer SIEM/syslog target.

**Priority 26 — SSH gateway mTLS for bastion hosts:**
The SSH credential gateway (port 8443) does not request client
certificates from bastion hosts. It relies on source-IP firewall
restriction + Vault token authentication. Issue each bastion a unique
client certificate via a dedicated PKI role and add
`ssl_verify_client on` + `ssl_client_certificate` to the gateway vhost
for independent bastion identity verification. CAB reviewer R1
recommendation.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — PKI role `bastion-gateway-client`; gateway
`ssl_verify_client on` + CRL + `OU=Bastion Gateway` allow-list; cert
issued to the controller's `.bastion/`.

**Priority 27 — SSH gateway HTTP method restriction:**
The SSH gateway location blocks accept all HTTP methods. The credential
issuance endpoints (`/v1/ssh-otp/creds/` and `/v1/ssh-ca/sign/`) only
require POST. Add `limit_except POST { deny all; }` to both location
blocks to prevent GET, PUT, DELETE, and other methods from reaching
Vault. CAB reviewer R1 recommendation.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — `limit_except POST PUT { deny all; }` on both gateway paths
(the Vault CLI writes with PUT, so PUT must stay allowed).

**Priority 28 — Default-deny catch-all for port 8443:**
The default-deny virtual host (`default-deny.conf`) covers port 443
only. Port 8443 (SSH gateway) has no separate default server block for
unknown hostnames. Add a default_server block on port 8443 that returns
444, matching the port 443 pattern. CAB reviewer R1 recommendation.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — **adapted**: the bastion connects by IP without SNI, so a
separate catch-all would break it and bypass mTLS. The gateway stays the
8443 `default_server` and returns 444 for any `Host` other than the VM
address or `vault-ssh-gateway.internal`.

**Priority 29 — CSP report-uri / report-to endpoint:**
The Content-Security-Policy-Report-Only header has no `report-uri` or
`report-to` directive. Without a reporting endpoint, CSP violations are
only visible in browser DevTools, not server-side. Configure a local
reporting endpoint or use Vault's native UI header mechanism once CSP is
promoted to enforcing mode. CAB reviewer R1 and MDN best practice.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — `report-uri /csp-report` → loopback-only sink (port 8008,
already `http_port_t`) so nginx logs the JSON report to
`csp-report.log`.

**Priority 30 — Fedora lifecycle / RHEL migration evaluation:**
Fedora has an approximately 13-month release maintenance lifecycle,
requiring frequent major-version upgrades. For a customer-facing
production secrets management platform, evaluate migration to RHEL 9 or
RHEL 10 for longer support cycles, controlled package updates, and a
defined Nginx/Vault upgrade schedule. CAB reviewer R1 raised this as a
production platform concern.

**Status:** Deferred — 2026-11-25 — platform decision for the customer.

**Priority 31 — Structured JSON access logging for SIEM:**
The current `vault_mtls` log format uses flat text fields. Convert to
structured JSON format with dedicated keys for cert serial, DN,
fingerprint, cipher, request method, URI (without query string), status,
and upstream timing. This enables immediate SIEM parsing and alerting on
specific revoked serials or unexpected cipher negotiations. CAB reviewers
R1, R2, and R3 consensus.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — `log_format vault_mtls_json escape=json` (cert
serial/DN/fingerprint, TLS protocol/cipher, `$uri` without query string)
on the proxy and gateway vhosts.

**Priority 32 — Browser Cache-Control response headers:**
Disabling Nginx's proxy cache (`proxy_cache off`) prevents server-side
caching but does not instruct browsers or intermediate proxies to avoid
caching sensitive Vault responses. Add
`Cache-Control: no-store, no-cache, must-revalidate, private` and
`Pragma: no-cache` to the security-headers.inc snippet. CAB reviewer R1
identified this gap.

**Status:** Resolved — 2026-11-25 — passed post-redeploy
validation — `Cache-Control: no-store, no-cache, must-revalidate,
private` and `Pragma: no-cache` in `security-headers.inc`.
