# Naming, Style, and Linter Conventions

Standards for every Ansible file in this project. Read this before your
first PR; reviewers will check against it.

---

## Table of Contents

- [Task Naming](#task-naming)
- [Handler Naming](#handler-naming)
- [Variable Naming](#variable-naming)
- [Fully Qualified Collection Names (FQCN)](#fully-qualified-collection-names-fqcn)
- [Booleans](#booleans)
- [Import Tasks vs Include Tasks](#import-tasks-vs-include-tasks)
- [File and Directory Naming](#file-and-directory-naming)
- [Role Structure](#role-structure)
- [Key Ordering in Task Blocks](#key-ordering-in-task-blocks)
- [Playbook Syntax](#playbook-syntax)
- [Comments](#comments)
- [SELinux Policy Conventions](#selinux-policy-conventions)
- [Hardware Detection](#hardware-detection)
- [Enforcement Summary](#enforcement-summary)

---

## Task Naming

Pattern: **`{Stem} | Sentence case imperative verb description`**

The stem is derived from the task file's name, converted to **Title Case**.
The description after the pipe uses sentence case and starts with an
imperative verb. No trailing period.

### Examples by file

| Task file           | Stem            | Full task name                                         |
|---------------------|-----------------|--------------------------------------------------------|
| `configure.yml`     | `Configure`     | `Configure \| Deploy vault.hcl configuration`          |
| `pki_engine.yml`    | `Pki Engine`    | `Pki Engine \| Mount Root CA PKI engine`               |
| `disable_swap.yml`  | `Disable Swap`  | `Disable Swap \| Mask zram swap generator`             |
| `tls_bootstrap.yml` | `Tls Bootstrap` | `Tls Bootstrap \| Generate self-signed CA certificate` |
| `browser_trust.yml` | `Browser Trust` | `Browser Trust \| Import CA into system trust store`   |

### Dispatcher `main.yml` files

Dispatcher files use plain descriptive names **without** a stem prefix.
These files are short import lists; a `Main |` prefix adds no value.

```yaml
# roles/common/tasks/main.yml
- name: Import install tasks
  ansible.builtin.import_tasks: install.yml

- name: Import configure tasks
  ansible.builtin.import_tasks: configure.yml
```

### Playbook `pre_tasks` / `post_tasks`

Tasks in `playbooks/site.yml` (or any playbook) use plain sentence-case
imperative verbs **without** a file-stem prefix.

```yaml
pre_tasks:
  - name: Gather minimum facts
    ansible.builtin.setup:
      gather_subset: min

post_tasks:
  - name: Print deployment summary
    ansible.builtin.debug:
      msg: "Deployment complete"
```

### Why not auto-enforced?

The built-in ansible-lint `name[prefix]` rule only accepts lowercase stems.
Our convention uses Title Case, so enforcement is via **PR review** and this
document.

---

## Handler Naming

**Simple restart/reload** -- use `Verb service-noun`:

```yaml
- name: Restart vault
  ansible.builtin.systemd_service:
    name: vault.service
    state: restarted

- name: Reload nginx
  ansible.builtin.systemd_service:
    name: nginx.service
    state: reloaded

- name: Reload systemd daemon
  ansible.builtin.systemd_service:
    daemon_reload: true
```

**Complex multi-step** -- use a descriptive sentence:

```yaml
- name: Compile and install Vault SELinux policy
  ansible.builtin.shell:
    cmd: |
      set -euo pipefail
      cd {{ vault_selinux_dir }}
      make -f /usr/share/selinux/devel/Makefile vault.pp
      semodule -i vault.pp
  changed_when: true
```

---

## Variable Naming

All variables use `snake_case`. No `camelCase`, no `UPPERCASE`.

### Scope prefixes

| Scope                      | Pattern                    | Example                                |
|----------------------------|----------------------------|----------------------------------------|
| Role defaults (public API) | `{role_name}_{variable}`   | `dns_do_ip4`, `vault_pki_key_type`     |
| Registered / internal      | `__{role_name}_{variable}` | `__dns_threads`, `__vault_init_output` |
| Loop variables             | `__` prefix                | `__pkg`, `__svc`                       |

### Role defaults -- public API

```yaml
# roles/dns/defaults/main.yml
dns_do_ip4: true
dns_do_ip6: true
dns_blocklist_enabled: true
```

### Registered / internal variables

Double-underscore prefix signals "do not set this in inventory":

```yaml
- name: Configure | Set number of threads
  ansible.builtin.set_fact:
    __dns_threads: >-
      {{ dns_num_threads if (dns_num_threads | int) > 0
         else ansible_facts['processor_vcpus'] | default(1) }}
```

### Loop variables

Always pass `loop_var` with a `__` prefix to avoid collisions:

```yaml
- name: Install | Install required packages
  ansible.builtin.dnf:
    name: '{{ __pkg }}'
    state: present
  loop: '{{ dns_packages }}'
  loop_control:
    loop_var: __pkg
```

### Enforcement

- ansible-lint `var-naming` rule with pattern `^[a-z_][a-z0-9_]*$`
- ansible-lint `loop_var_prefix: "__"` (config: `.ansible-lint`)

---

## Fully Qualified Collection Names (FQCN)

Every module call must use its FQCN. No bare module names.

```yaml
# Correct
- name: Configure | Deploy main configuration
  ansible.builtin.template:
    src: unbound.conf.j2
    dest: /etc/unbound/unbound.conf

# Wrong -- bare module name
- name: Configure | Deploy main configuration
  template:
    src: unbound.conf.j2
    dest: /etc/unbound/unbound.conf
```

Common FQCNs used in this project:

| Bare name         | FQCN                              |
|-------------------|-----------------------------------|
| `command`         | `ansible.builtin.command`         |
| `shell`           | `ansible.builtin.shell`           |
| `template`        | `ansible.builtin.template`        |
| `copy`            | `ansible.builtin.copy`            |
| `file`            | `ansible.builtin.file`            |
| `dnf`             | `ansible.builtin.dnf`             |
| `systemd_service` | `ansible.builtin.systemd_service` |
| `set_fact`        | `ansible.builtin.set_fact`        |
| `debug`           | `ansible.builtin.debug`           |
| `assert`          | `ansible.builtin.assert`          |
| `uri`             | `ansible.builtin.uri`             |
| `import_tasks`    | `ansible.builtin.import_tasks`    |
| `include_tasks`   | `ansible.builtin.include_tasks`   |

### Enforcement

ansible-lint FQCN rule (enabled by `profile: production` in
`.ansible-lint`).

---

## Booleans

Use **`true` / `false`** only (YAML 1.2 strict). Never `yes` / `no`,
`True` / `False`, `on` / `off`, or any other truthy/falsy variant.

```yaml
# Correct
dns_do_ip4: true
dns_do_ip6: false

# Wrong
dns_do_ip4: yes
dns_do_ip6: no
```

### Enforcement

yamllint `truthy` rule with `allowed-values: ["true", "false"]` (config:
`lint/.yamllint.yml`).

---

## Import Tasks vs Include Tasks

| Use `import_tasks` when...        | Use `include_tasks` when...             |
|-----------------------------------|-----------------------------------------|
| Sub-file is unconditional         | Sub-file has a `when:` condition        |
| Execution order is fixed          | Sub-file needs looping                  |
| Tags should propagate down        | Tags should NOT propagate               |
| File contains only static content | File uses dynamic variables in the path |

### Typical dispatcher pattern (import_tasks)

```yaml
# roles/dns/tasks/main.yml
- name: Import install tasks
  ansible.builtin.import_tasks: install.yml
  tags:
    - dns
    - dns:install

- name: Import configure tasks
  ansible.builtin.import_tasks: configure.yml
  tags:
    - dns
    - dns:configure
```

### Conditional inclusion (include_tasks)

```yaml
- name: Import blocklist tasks
  ansible.builtin.include_tasks: blocklist.yml
  when: dns_blocklist_enabled | bool
  tags:
    - dns
    - dns:blocklist
```

### Rule of thumb

Default to `import_tasks`. Switch to `include_tasks` only when you need
conditional execution, looping, or tag isolation. Be consistent within a
role -- don't mix without reason.

This convention is **documented only**, not auto-enforced.

---

## File and Directory Naming

| Category                 | Convention                                        | Example                                    |
|--------------------------|---------------------------------------------------|--------------------------------------------|
| Task files               | `lowercase_underscores.yml`                       | `pki_engine.yml`, `disable_swap.yml`       |
| Templates                | `descriptive-name.ext.j2` (match target filename) | `vault.hcl.j2`, `unbound.conf.j2`          |
| Vars files               | OS family in Title Case                           | `RedHat.yml`                               |
| Role names               | `lowercase` (no underscores)                      | `dns`, `vault`, `common`                   |
| Static files             | Match the target filename                         | `sshd-vault-ssh-helper.te`                 |
| Ansible YAML             | `.yml` extension                                  | `main.yml`, `configure.yml`                |
| Non-Ansible tool configs | `.yaml` acceptable                                | `.yamllint.yml`, `.markdownlint-cli2.yaml` |

### Why `.yml` for Ansible files?

Ansible defaults to `.yml` in its skeleton generator, Galaxy, and most
official examples. Using `.yml` consistently avoids confusion when glob
patterns or linter configs need to match Ansible files versus tool configs.

---

## Role Structure

Every role **must** have at minimum:

```text
roles/myrole/
  defaults/main.yml    # Public API variables (always present, even if empty)
  tasks/main.yml       # Entry point (dispatcher if sub-files exist)
  meta/main.yml        # Galaxy metadata + dependencies
```

Add these directories as needed:

```text
  handlers/main.yml    # Service restart/reload handlers
  templates/           # Jinja2 templates (.j2)
  files/               # Static files (SELinux policies, scripts, etc.)
  vars/                # OS-specific variables (RedHat.yml, Debian.yml)
```

### Splitting task files

Split a task file when it exceeds **~15 tasks**. Group by logical function:
`install.yml`, `configure.yml`, `service.yml`, etc.

The `main.yml` becomes a dispatcher that imports the sub-files:

```yaml
# roles/auth/tasks/main.yml (dispatcher)
- name: Import install tasks
  ansible.builtin.import_tasks: install.yml

- name: Import configure tasks
  ansible.builtin.import_tasks: configure.yml

- name: Import authselect tasks
  ansible.builtin.import_tasks: authselect.yml

- name: Import selinux tasks
  ansible.builtin.import_tasks: selinux.yml
```

---

## Key Ordering in Task Blocks

Keys within a task block follow this order:

1. `name` (always first)
2. Modifiers: `when`, `tags`, `block`, `become`, `become_user`
3. Module name (e.g., `ansible.builtin.template`)
4. Module arguments

```yaml
# Correct key ordering
- name: Configure | Deploy main configuration
  become: true
  tags:
    - dns
    - dns:configure
  ansible.builtin.template:
    src: unbound.conf.j2
    dest: /etc/unbound/unbound.conf
    owner: root
    group: unbound
    mode: '0640'
  notify: Restart unbound
```

### Enforcement

ansible-lint `key-order` rule (enabled by `profile: production` in
`.ansible-lint`).

---

## Playbook Syntax

Play-level keys follow this order:

1. `name`
2. `hosts`
3. `become`
4. `tags`
5. `pre_tasks`
6. `roles`
7. `post_tasks`
8. `handlers`

```yaml
- name: "Phase 1: Bootstrap"
  hosts: workstation
  become: true
  tags:
    - bootstrap
  pre_tasks:
    - name: Gather minimum facts
      ansible.builtin.setup:
        gather_subset: min
  roles:
    - common
    - dns
    - vault
  post_tasks:
    - name: Print bootstrap summary
      ansible.builtin.debug:
        msg: "Bootstrap complete"
```

---

## Comments

### Section dividers

Use `# ===` (or `# ---`) dividers to separate major logical blocks within
task files:

```yaml
# ===================================================================
# TLS certificate bootstrap
# ===================================================================
- name: Tls Bootstrap | Generate self-signed CA certificate
  ...

# ===================================================================
# Vault initialization
# ===================================================================
- name: Init | Initialize Vault server
  ...
```

### Inline comments

Add inline `#` comments for non-obvious logic -- skip the rest:

```yaml
# Fix stale SELinux context on ansible remote_tmp after reboot.
# After Phase 2 hardening maps the admin to staff_u, the next
# SSH login transitions to sysadm_t.
- name: Ensure ansible remote tmp is accessible
  ansible.builtin.raw: >-
    sudo restorecon -F /root/.ansible/tmp 2>/dev/null || true

- name: Configure | Set number of threads
  ansible.builtin.set_fact:
    __dns_threads: >-    # Falls back to vCPU count if dns_num_threads is 0
      {{ dns_num_threads if (dns_num_threads | int) > 0
         else ansible_facts['processor_vcpus'] | default(1) }}
```

Don't comment the obvious:

```yaml
# Bad -- adds no information
# Install the unbound package
- name: Install | Install unbound
  ansible.builtin.dnf:
    name: unbound
    state: present
```

---

## SELinux Policy Conventions

### Module Naming

Pattern: **`{daemon}-{target}.te`** — one narrowly-scoped module per
distinct (source domain, target type) pair. Each module ships as a
`.te` / `.if` / `.fc` triplet.

| Module file                | Source domain               | Target type            |
|----------------------------|-----------------------------|------------------------|
| `fapolicyd-gdm.te`         | `fapolicyd_t`               | `xdm_t`                |
| `logind-usbguard.te`       | `systemd_logind_t`          | `usbguard_t`           |
| `usbguard-gdm.te`          | `usbguard_t`                | `xdm_t`                |
| `auditctl-log.te`          | `auditctl_t`                | `var_log_t`            |
| `sshd-vault-ssh-helper.te` | `sshd_t` / `sshd_session_t` | `vault_cluster_port_t` |

The handler in `roles/auth/handlers/main.yml` compiles **all** `*.te`
files found in the `auth_selinux_dir` directory, so adding a new module
only requires dropping the triplet into that directory and notifying
the handler.

### Dontaudit Debugging

When a permission denial fails silently (no AVC in `ausearch`), the
kernel may be suppressing the denial via a `dontaudit` rule. Standard
diagnostic procedure:

1. `semodule -DB` — temporarily disable **all** `dontaudit` rules
2. Reproduce the failing action
3. `ausearch -m AVC -ts recent` — capture the now-visible denials
4. `semodule -B` — re-enable `dontaudit` rules immediately after

This technique was used to discover the hidden `sshd_session_t` `open`
permission denial on `var_log_t:file` for vault-ssh-helper.

### File-Class Permission Pattern

For the SELinux `file` class, **both** `open` **and** the specific
access permission (`read`, `append`, `write`, etc.) are independently
required as **separate** `allow` rules. For the `dir` class, typically
only the access permission (`read`, `search`, etc.) is needed
**without** a separate `open`.

| Module                     | Class | Permissions needed             |
|----------------------------|-------|--------------------------------|
| `auditctl-log.te`          | file  | `open` + `read` (two allows)   |
| `auditctl-log.te`          | dir   | `read` only (no `open`)        |
| `sshd-vault-ssh-helper.te` | file  | `open` + `append` (two allows) |

### Fedora 44 `sshd_session_t` Gotcha

OpenSSH 10.2p1's re-exec architecture splits the sshd process into
two SELinux domains:

- **`sshd_t`** — the persistent listener daemon
- **`sshd_session_t`** — the per-connection session handler (executes
  PAM stack, spawns user shell)

SELinux modules targeting sshd PAM extensions (such as
vault-ssh-helper) **must** target `sshd_session_t`, not just `sshd_t`.
The existing `sshd-vault-ssh-helper.te` v1.2.0 covers **both** domains
for forward compatibility.

---

## Hardware Detection

Prefer runtime hardware detection over static VM/bare-metal
assumptions. Key patterns:

| Detection goal     | Recommended approach               | Avoid                 |
|--------------------|------------------------------------|-----------------------|
| Sound card present | `/proc/asound/cards` line count    | Blanket VM-only gate  |
| VM vs bare-metal   | `ansible_virtualization_role` fact | Static inventory flag |

**Example:** ALSA masking uses card-count detection — this correctly
handles VMs **with** virtual sound cards and headless physical servers
**without** sound cards, rather than a blanket "skip if VM" gate that
would be wrong in both edge cases.

---

## Enforcement Summary

| Convention                        | Enforced by                              | Config file                               |
|-----------------------------------|------------------------------------------|-------------------------------------------|
| FQCN (no bare modules)            | ansible-lint `fqcn` rule                 | `.ansible-lint` (`profile: production`)   |
| Variable naming pattern           | ansible-lint `var-naming` rule           | `.ansible-lint` (`var_naming_pattern`)    |
| Loop variable prefix              | ansible-lint `loop_var_prefix`           | `.ansible-lint` (`loop_var_prefix: "__"`) |
| Key ordering in tasks             | ansible-lint `key-order` rule            | `.ansible-lint` (`profile: production`)   |
| Jinja2 template extension         | ansible-lint `jinja[template-extension]` | `.ansible-lint` (`enable_list`)           |
| Booleans `true`/`false` only      | yamllint `truthy` rule                   | `lint/.yamllint.yml`                      |
| Line length ≤ 200                 | yamllint `line-length` rule              | `lint/.yamllint.yml`                      |
| Octal values explicit             | yamllint `octal-values` rule             | `lint/.yamllint.yml`                      |
| Task naming (`{Stem} \| ...`)     | **PR review**                            | This document                             |
| Handler naming                    | **PR review**                            | This document                             |
| `import_tasks` vs `include_tasks` | **PR review**                            | This document                             |
| File/directory naming             | **PR review**                            | This document                             |
| Role structure / split threshold  | **PR review**                            | This document                             |
| Playbook key ordering             | **PR review**                            | This document                             |
| Comment style                     | **PR review**                            | This document                             |
| SELinux module naming             | **PR review**                            | This document                             |
| SELinux dontaudit debugging       | **PR review**                            | This document                             |
| SELinux file-class permissions    | **PR review**                            | This document                             |
| `sshd_session_t` domain targeting | **PR review**                            | This document                             |
| Hardware detection patterns       | **PR review**                            | This document                             |

All linters run via `make lint` inside the Podman container defined in
`lint/Containerfile.lint`. See [../CONTRIBUTING.md](../CONTRIBUTING.md) for
the development workflow.
