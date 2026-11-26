#!/usr/bin/env bash
# =============================================================================
# lint/ci-local.sh -- Local dry run of the GitHub Actions lint pipeline
# =============================================================================
# Reproduces .github/workflows/lint.yml before you push, so CI failures are
# caught locally. Differences from `make lint` are deliberate:
#
#   * Lints a SNAPSHOT of what would be pushed: tracked files (including
#     uncommitted edits) plus new files that are not gitignored. Vendored
#     roles/collections, .venv and secrets are never included -- exactly
#     like a fresh `actions/checkout`.
#   * No bind mount: the container sees only the snapshot, and fresh
#     Galaxy roles/collections installed inside the image.
#   * Busts the pip layer cache on every run so lint tool versions match
#     what CI installs from requirements-lint.txt today.
#   * Runs lint-all.sh with --check (no auto-fix), like CI.
#
# Usage: make ci     (or: bash lint/ci-local.sh)
# Exit:  0 all checks passed, non-zero otherwise.
# =============================================================================
set -euo pipefail

readonly IMG="ansible-workstation-lint-ci"
readonly CONTAINERFILE="lint/Containerfile.lint"

cd "$(git rev-parse --show-toplevel)"

SNAP="$(mktemp -d "${TMPDIR:-/tmp}/ci-local.XXXXXX")"
cleanup() { rm -rf "$SNAP"; }
trap cleanup EXIT

printf '\033[1;36m==> Snapshotting tracked + new (non-ignored) files\033[0m\n'
git ls-files -z --cached --others --exclude-standard |
	rsync -a --from0 --files-from=- ./ "$SNAP/"
printf '    %s files\n' "$(find "$SNAP" -type f | wc -l)"

printf '\033[1;36m==> Building lint image (fresh base + fresh lint tools)\033[0m\n'
podman build --pull=newer \
	--build-arg "CACHEBUST=$(date +%s)" \
	-t "$IMG" -f "$SNAP/$CONTAINERFILE" "$SNAP"

printf '\033[1;36m==> Running CI-equivalent checks (verify-only)\033[0m\n'
podman run --rm "$IMG" bash lint/lint-all.sh --check
