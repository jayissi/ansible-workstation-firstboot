#!/usr/bin/env bash
# =============================================================================
# Idempotency check: run the full playbook again on an already-deployed host
# and compare the PLAY RECAP "changed=" total with a recorded baseline.
#
# Some vendored linux-system-roles report changed on every run (see
# docs/KNOWN_ISSUES.md "Vendor-Role Non-Idempotency"), so the target is
# "no MORE changes than the baseline", not zero.
#
# Usage: tests/idempotency.sh <max-changed> [log-file]
# Exit 0 = within baseline, 1 = more changes than baseline or failures.
# =============================================================================
set -euo pipefail

MAX_CHANGED="${1:?usage: $0 <max-changed> [log-file]}"
LOG="${2:-idempotency-$(date +%Y%m%d-%H%M%S).log}"

echo "==> Idempotency re-run (baseline: changed <= ${MAX_CHANGED}); log: ${LOG}"
ansible-playbook playbooks/site.yml >"$LOG" 2>&1 || {
	echo "FAIL: playbook re-run failed -- see ${LOG}" >&2
	tail -20 "$LOG" >&2
	exit 1
}

recap=$(grep -A5 '^PLAY RECAP' "$LOG" | grep -E 'changed=[0-9]+' | tail -1)
changed=$(sed -E 's/.*changed=([0-9]+).*/\1/' <<<"$recap")
failed=$(sed -E 's/.*failed=([0-9]+).*/\1/' <<<"$recap")
echo "    ${recap}"

if [[ "$failed" -ne 0 ]]; then
	echo "FAIL: ${failed} task(s) failed on the re-run" >&2
	exit 1
fi
if [[ "$changed" -gt "$MAX_CHANGED" ]]; then
	echo "FAIL: changed=${changed} exceeds baseline ${MAX_CHANGED}. Changed tasks:" >&2
	grep -B1 '^changed:' "$LOG" | grep '^TASK' | sed 's/^/    /' >&2 || true
	exit 1
fi
echo "PASS: changed=${changed} (baseline ${MAX_CHANGED})"
