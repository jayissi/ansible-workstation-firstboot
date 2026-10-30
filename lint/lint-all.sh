#!/usr/bin/env bash
# =============================================================================
# lint/lint-all.sh -- Single-entry lint pipeline for Ansible Workstation
# =============================================================================
# Runs inside the Podman lint container (see lint/Containerfile.lint).
# Called by: `make lint` (bind-mounted, auto-fix enabled)
#            `podman run --rm $(LINT_IMG)` (standalone, verify-only)
#
# Exit codes:
#   0  All checks passed
#   1  One or more linters reported violations
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly VENV="/opt/.venv"
readonly VAULT_PASS_FILE=".vault_pass.txt"

# Docs scanned by multiple tools -- single source of truth
readonly -a DOCS=(
	README.md
	CONTRIBUTING.md
	SECURITY.md
	docs/CHANGELOG.md
	docs/*.md
	docs/decisions/*.md
)

# Roles containing project-owned code (excludes vendored Galaxy content)
readonly -a PROJECT_ROLES=(
	roles/common/
	roles/dns/
	roles/avahi/
	roles/vault/
	roles/proxy/
	roles/verification/
)

# Additional paths for spell-checking (superset of PROJECT_ROLES)
readonly -a CODESPELL_EXTRA=(
	inventory/
	playbooks/
	Makefile
	pyproject.toml
	lint/
	ansible.cfg
	requirements-lint.txt
	requirements-rpm.txt
	.github/
)

# Shell scripts owned by this project
readonly -a SHELL_SCRIPTS=(
	roles/common/files/bin/*
	roles/common/files/bashrc.d/*
)

# SELinux policy directories
readonly -a SELINUX_DIRS=(
	roles/auth/files/selinux/
	roles/dns/files/selinux/
	roles/vault/files/selinux/
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_log() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
_pass() { printf '    \033[1;32m✓ %s\033[0m\n' "$1"; }
_fail() { printf '    \033[1;31m✗ %s\033[0m\n' "$1"; }

LINTER_COUNT=0

run_linter() {
	local name="$1"
	shift
	LINTER_COUNT=$((LINTER_COUNT + 1))
	_log "$name"
	if "$@"; then
		_pass "$name"
	else
		_fail "$name"
		FAILURES+=("$name")
	fi
}

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
if [[ ! -d "$VENV" ]]; then
	echo "FATAL: lint venv not found at $VENV" >&2
	echo "       This script must run inside the lint container." >&2
	exit 1
fi

# shellcheck source=/dev/null
. "${VENV}/bin/activate"

# ansible-lint calls ansible-playbook --syntax-check internally, which
# requires vault_password_file to exist (ansible.cfg references it).
# Create a placeholder -- syntax-check never actually decrypts anything.
[[ -f "$VAULT_PASS_FILE" ]] || echo "ci-lint-placeholder" >"$VAULT_PASS_FILE"

# ---------------------------------------------------------------------------
# Auto-fix phase (best-effort, non-fatal)
# ---------------------------------------------------------------------------
# Only meaningful when the workspace is bind-mounted from the host
# (-v $(CURDIR):/workspace:z) so fixes persist after the container
# exits.  In standalone / CI mode, these are harmless no-ops since the
# container filesystem is ephemeral.
# ---------------------------------------------------------------------------
_log "Auto-fix (best-effort)"
ruff check --fix . 2>/dev/null && _pass "ruff --fix" || true
markdown-table-formatter "${DOCS[@]}" 2>/dev/null &&
	_pass "markdown-table-formatter" || true

# ---------------------------------------------------------------------------
# Verify phase (all linters, order: fast / broad → slow / narrow)
# ---------------------------------------------------------------------------
declare -a FAILURES=()

# -- YAML / Ansible (broad, catches the most common issues first) ----------
run_linter "yamllint" yamllint .
run_linter "ansible-lint" ansible-lint
run_linter "ruff" ruff check .
run_linter "pyright" pyright

# -- Markdown ---------------------------------------------------------------
run_linter "pymarkdown" pymarkdown --config lint/.pymarkdownlint.yml scan "${DOCS[@]}"
run_linter "markdownlint-cli2" markdownlint-cli2 --config lint/.markdownlint-cli2.yaml
run_linter "markdown-table-formatter" markdown-table-formatter --check "${DOCS[@]}"
run_linter "linkbust" linkbust "${DOCS[@]}"

# -- Spelling ---------------------------------------------------------------
run_linter "codespell" codespell "${PROJECT_ROLES[@]}" "${CODESPELL_EXTRA[@]}" "${DOCS[@]}"

# -- Security ---------------------------------------------------------------
run_linter "bandit" bandit -r "${PROJECT_ROLES[@]}" playbooks/
run_linter "checkov" checkov --config-file lint/.checkov.yaml -d .
run_linter "detect-secrets" detect-secrets scan --baseline lint/.secrets.baseline
run_linter "gitleaks" gitleaks detect --source . -c lint/.gitleaks.toml -v --redact --no-git

# -- Container / CI ---------------------------------------------------------
run_linter "hadolint" hadolint --config lint/.hadolint.yaml lint/Containerfile.lint
run_linter "actionlint" actionlint .github/workflows/*.yml

# -- Shell / SELinux --------------------------------------------------------
run_linter "shellcheck" shellcheck "${SHELL_SCRIPTS[@]}" lint/lint-all.sh
run_linter "shfmt" shfmt -d "${SHELL_SCRIPTS[@]}" lint/lint-all.sh
run_linter "selint" selint -r "${SELINUX_DIRS[@]}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if ((${#FAILURES[@]} == 0)); then
	printf '\033[1;32m✓ All %d linters passed.\033[0m\n' "$LINTER_COUNT"
else
	printf '\033[1;31m✗ %d of %d linters failed:\033[0m\n' "${#FAILURES[@]}" "$LINTER_COUNT"
	printf '    • %s\n' "${FAILURES[@]}"
	exit 1
fi
