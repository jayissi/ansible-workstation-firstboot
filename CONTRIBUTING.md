# Contributing

## Development Setup

```bash
# Install controller prerequisites (podman, ansible-core, git -- no lint tools)
sudo dnf install -y $(grep -v '^#' requirements-rpm.txt)

# Create venv for Ansible operations (deploy/verify/test -- NOT for linting)
make venv

# Install pre-commit hooks
source .venv/bin/activate
pre-commit install
```

Linting runs entirely inside Podman -- no lint tools are installed on the
host. Only `podman` and `make` are needed for `make lint`.

## Workflow

See [docs/CONVENTIONS.md](docs/CONVENTIONS.md) for naming and style conventions.

1. Create a feature branch: `git checkout -b feature/my-change`
2. Make changes
3. Run linters: `make lint` (runs inside Podman container, no venv needed)
4. Run syntax check: `make test`
5. Deploy to test target: `make deploy`
6. Verify: `make verify`
7. Commit and push

## Linting

All linters must pass before merging:

```bash
make lint                  # Run all linters inside Podman (single source of truth)
make lint-fix              # Auto-fix ruff + table alignment (runs inside Podman)
```

All linter configs live in the `lint/` directory (except `.ansible-lint`,
`pyproject.toml`, and `.pre-commit-config.yaml` which must stay at the
project root for tool discovery). The container image is built from
`lint/Containerfile.lint`.

## Adding New Packages

Add to `common_packages` in `inventory/group_vars/all/main.yml`.

## Adding New Roles

1. Add to `requirements.yml`
2. Run `make galaxy` to download
3. Add to `playbooks/site.yml` in the correct tier
4. Add variables to `inventory/group_vars/all/main.yml`

## Adding Variables

- Non-sensitive: `inventory/group_vars/all/main.yml`
- Sensitive: `inventory/group_vars/all/vault.yml` (Ansible Vault encrypted)

## Testing Against Fresh VM

1. Revert target VM to clean snapshot
2. Verify SSH access: `ansible workstation -m ping`
3. Run full playbook: `make deploy`
4. Verify: `make verify`
5. Test reboot survivability: reboot target, then `make verify`
