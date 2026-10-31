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
VaultPass (`kbndeonibamcpiibocdhlagccdlmefco`) are MV2-only extensions
with no MV3 versions available.

**Fix:** Removed all Chrome extension policies. Chrome retains only
bookmarks, DNS security, and auto-cert-select policies. Extensions are
Firefox-only for this project.

**Validation:** No extension-related errors in Chrome. Chrome policies
clean (bookmarks.json + dns-security.json only).

**Status:** Fixed (architectural constraint — MV2 is permanently removed
from Chrome).

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

### Vault Telemetry

Enable the `telemetry` stanza in `vault.hcl` for
Prometheus-compatible metrics. Zero-cost to enable (no scraper
required), provides future observability capability per HashiCorp's
hardening checklist.

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

### Duplicate sudo NOPASSWD Line

Both the base image and `00-hardening` drop-in contain a sudo
`NOPASSWD` line for the admin user. Identified during E2E validation
but not yet consolidated. Functionally harmless (sudo processes both,
second is redundant) but should be deduplicated.

### Vendor-Role Non-Idempotency

`linux-system-roles.tlog`, `linux-system-roles.tuned`, and
`linux-system-roles.fapolicyd` have unconditional `changed_when: true`
tasks. Confirmed-correct end-state via direct verification. Not a bug
to patch — the `collections/` directory is vendored and not modified
per project convention. `changed=18` on idempotent re-runs is the
established baseline.

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

**Priority 16 — Restrict DoT port 853 firewall rule to approved upstreams:**
The current rich rule `port port="853" protocol="tcp" accept` allows
any process to establish DoT connections to any external server.
Restrict to the specific upstream DoT resolver IPs (Quad9 and
Cloudflare) to prevent rogue applications from exfiltrating DNS queries
via unauthorized DoT tunnels. Supersedes Priority 10 (which flagged the
missing source filter; this item adds the destination filter).

**Priority 17 — DNSSEC operational verification test:**
Add a DNSSEC validation test to `roles/verification/tasks/network.yml`:
`dig @127.0.0.1 dnssec-failed.org` must return SERVFAIL (not a
successful resolution). dnsconfd's upstream README notes that "DNSSEC
validation is turned off to prevent potential problems" — the project's
`zz-module-override.conf` overrides this with
`module-config: "respip validator iterator"`, but runtime verification
is needed to confirm validation is actually active, not merely
configured.

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
