# =============================================================================
# Ansible Workstation Firstboot -- Makefile
# =============================================================================
#
# Targets:
#   setup     Install controller prerequisites (podman, ansible-core, git)
#   venv      Create Python venv and install Ansible + Galaxy dependencies
#   galaxy    Re-download Galaxy roles and collections only
#   lint      Auto-fix then run all linters (Podman container)
#   test      Syntax-check the playbook (dry run)
#   deploy    Run the full playbook against the target host
#   verify    Run post-deployment verification assertions
#   clean     Remove venv, caches, and lint container image
#
# Prerequisites:
#   - podman (for linting)
#   - python3 + make (for everything else)
#   See requirements-rpm.txt for the full list.
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VENV           := .venv
LINT_IMG       := ansible-workstation-lint
LINT_CONTAINER := lint/Containerfile.lint
PLAYBOOK       := playbooks/site.yml

# ---------------------------------------------------------------------------
# Derived paths (not user-configurable)
# ---------------------------------------------------------------------------
ACTIVATE := . $(VENV)/bin/activate

# ---------------------------------------------------------------------------
# Guard: require venv for Ansible targets
# ---------------------------------------------------------------------------
define require_venv
	@if [ ! -d "$(VENV)/bin" ]; then \
		printf '\033[1;31mError:\033[0m venv not found. Run \033[36mmake venv\033[0m first.\n' >&2; \
		exit 1; \
	fi
endef

.DEFAULT_GOAL := help

# =============================================================================
# Help
# =============================================================================
.PHONY: help

help: ## Show available targets
	@printf '\n\033[1mUsage:\033[0m make \033[36m<target>\033[0m\n\n'
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'
	@echo ""

# =============================================================================
# Environment setup
# =============================================================================
.PHONY: setup venv galaxy

setup: ## Install controller prerequisites (podman, ansible-core, git)
	sudo dnf install -y $$(grep -v '^\#' requirements-rpm.txt)

venv: ## Create venv, install Ansible + Galaxy roles/collections
	python3 -m venv $(VENV)
	$(ACTIVATE) && python -m pip install --upgrade pip
	$(ACTIVATE) && pip install -r requirements.txt
	$(ACTIVATE) && ansible-galaxy collection install -r collections/requirements.yml --force
	$(ACTIVATE) && ansible-galaxy role install -r roles/requirements.yml --force -p roles/
	$(ACTIVATE) && pre-commit install
	@printf '\033[1;32m✓\033[0m venv ready. Run \033[36msource %s/bin/activate\033[0m to use.\n' "$(VENV)"

# =============================================================================
# Linting (Podman -- single source of truth, keeps host clean)
# =============================================================================
.PHONY: lint clean

lint: ## Auto-fix then run all linters inside Podman container
	podman build -t $(LINT_IMG) -f $(LINT_CONTAINER) .
	podman run --rm -v $(CURDIR):/workspace:z $(LINT_IMG)

clean: ## Remove venv, caches, and lint container image
	rm -rf $(VENV) .ruff_cache __pycache__
	podman rmi $(LINT_IMG) 2>/dev/null || true
	@echo "Clean."

# =============================================================================
# Galaxy (requires venv)
# =============================================================================
galaxy: ## Re-download Galaxy roles and collections only
	$(call require_venv)
	$(ACTIVATE) && ansible-galaxy collection install -r collections/requirements.yml --force
	$(ACTIVATE) && ansible-galaxy role install -r roles/requirements.yml --force -p roles/

# =============================================================================
# Deployment and operations (requires venv)
# =============================================================================
.PHONY: test deploy verify vault-rotate-root-token

test: ## Syntax-check the playbook (dry run)
	$(call require_venv)
	$(ACTIVATE) && ansible-playbook $(PLAYBOOK) --syntax-check
	@printf '\033[1;32m✓\033[0m Syntax check passed. Run \033[36mmake deploy\033[0m for full deployment.\n'

deploy: ## Run the full playbook against the target host
	$(call require_venv)
	$(ACTIVATE) && ansible-playbook $(PLAYBOOK)

verify: ## Run post-deployment verification assertions
	$(call require_venv)
	$(ACTIVATE) && ansible-playbook $(PLAYBOOK) --tags verify

vault-rotate-root-token: ## Rotate the Vault root token (on-demand)
	$(call require_venv)
	$(ACTIVATE) && ansible-playbook $(PLAYBOOK) \
		--tags vault-rotate-token -e vault_rotate_root_token=true
