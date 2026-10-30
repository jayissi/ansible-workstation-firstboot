#!/usr/bin/env bash
# Shared commands for the fedora-native CI job and make smoke-fedora-native.
# Expects gitleaks, hadolint, selint, shfmt already installed via dnf.
# All linter configs live in the lint/ directory alongside this script.
set -euo pipefail
gitleaks detect --source . -c lint/.gitleaks.toml -v --redact --no-git
hadolint --config lint/.hadolint.yaml lint/Containerfile.lint
selint -r roles/auth/files/selinux/ roles/dns/files/selinux/ roles/vault/files/selinux/
shfmt -d roles/common/files/bin/* roles/common/files/bashrc.d/*
