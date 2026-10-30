# =============================================================================
# Ansible Workstation Firstboot -- Makefile
# =============================================================================
VENV     := .venv
LINT_IMG := ansible-workstation-lint

.DEFAULT_GOAL := help

# Activate venv only for targets that need Ansible
deploy test verify vault-rotate-root-token: export VIRTUAL_ENV := $(CURDIR)/$(VENV)
deploy test verify vault-rotate-root-token: export PATH := $(CURDIR)/$(VENV)/bin:$(PATH)

# =============================================================================
# Environment setup
# =============================================================================
.PHONY: help setup venv galaxy

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'

setup: ## Install controller prerequisites (podman, ansible-core, git)
	sudo dnf install -y $$(grep -v '^#' requirements-rpm.txt)

venv: ## Create venv for Ansible operations (deploy/verify/test -- not linting)
	python3 -m venv $(VENV)
	$(VENV)/bin/python -m pip install --upgrade pip
	$(VENV)/bin/python -m pip install -r requirements.txt
	$(VENV)/bin/ansible-galaxy collection install -r collections/requirements.yml --force
	$(VENV)/bin/ansible-galaxy role install -r roles/requirements.yml --force -p roles/
	$(VENV)/bin/pre-commit install

galaxy: ## Download Galaxy roles and collections only
	$(VENV)/bin/ansible-galaxy collection install -r collections/requirements.yml --force
	$(VENV)/bin/ansible-galaxy role install -r roles/requirements.yml --force -p roles/

# =============================================================================
# Linting -- Podman only (single source of truth, keeps host clean)
# =============================================================================
.PHONY: lint lint-fix clean

lint: ## Run all linters inside Podman container
	podman build -t $(LINT_IMG) -f lint/Containerfile.lint .
	podman run --rm $(LINT_IMG)

lint-fix: ## Auto-fix ruff + table alignment (runs inside Podman, writes back via volume mount)
	podman build -t $(LINT_IMG) -f lint/Containerfile.lint .
	podman run --rm -v $(CURDIR):/workspace:z $(LINT_IMG) bash -c \
		'. .venv/bin/activate && ruff check --fix . && markdown-table-formatter README.md CONTRIBUTING.md'

clean: ## Remove venv, caches, and lint container image
	rm -rf .venv .ruff_cache
	podman rmi $(LINT_IMG) 2>/dev/null || true

# =============================================================================
# Deployment and operations (local venv, SSH to target)
# =============================================================================
.PHONY: test deploy verify vault-rotate-root-token

test: ## Syntax check and dry run
	ansible-playbook playbooks/site.yml --syntax-check
	@echo "Syntax check passed. Run 'make deploy' for full deployment."

deploy: ## Run the full playbook against target
	ansible-playbook playbooks/site.yml

verify: ## Run verification assertions only
	ansible-playbook playbooks/site.yml --tags verify

vault-rotate-root-token: ## Rotate the Vault root token (on-demand)
	ansible-playbook playbooks/site.yml \
		--tags vault-rotate-token -e vault_rotate_root_token=true
