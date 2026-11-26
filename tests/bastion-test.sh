#!/usr/bin/env bash
# =============================================================================
# SSH gateway tests from the BASTION side (run on the controller, which is
# also the bastion in this lab). Uses the bastion client certificate that
# `make deploy` writes to .bastion/ (KNOWN_ISSUES P26).
#
# Usage: tests/bastion-test.sh <workstation-ip> [cert-dir] [ca-file]
# Exit 0 = all pass, exit 1 = any fail
# =============================================================================
# Test functions are invoked indirectly via run_test "<name>" <fn>; the
# linter cannot follow that, so SC2329 ("function never invoked"; SC2317
# on the older ShellCheck pinned in pre-commit) is a false positive here.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

TARGET="${1:?usage: $0 <workstation-ip> [cert-dir] [ca-file]}"
CERT_DIR="${2:-.bastion}"
CA_FILE="${3:-${CERT_DIR}/client.crt}"
GW="https://${TARGET}:8443"
CERT=(--cert "${CERT_DIR}/client.crt" --key "${CERT_DIR}/client.key")

PASS=0
FAIL=0
run_test() {
	local name="$1"
	shift
	if "$@"; then
		PASS=$((PASS + 1))
		printf "  \033[32mPASS\033[0m  %s\n" "$name"
	else
		FAIL=$((FAIL + 1))
		printf "  \033[31mFAIL\033[0m  %s\n" "$name"
	fi
}

# The gateway's server cert chains to the Vault Root CA; the bastion cert
# bundle contains the issuing (Intermediate) CA only, so verification of
# the server name is skipped here (-k) -- these tests exercise access
# control, not server identity. The bastion's real client uses VAULT_CACERT.
status() { curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$@"; }

test_no_cert_refused() {
	local c
	c=$(status -X PUT "${GW}/v1/ssh-otp/creds/daily")
	[[ "$c" == "400" || "$c" == "000" ]]
}

test_allowed_path_reaches_vault() {
	local body
	body=$(curl -sk --max-time 8 "${CERT[@]}" -X PUT "${GW}/v1/ssh-otp/creds/daily")
	# No Vault token sent: Vault itself answers with a JSON error.
	echo "$body" | grep -q '"errors"'
}

test_method_restricted() {
	[[ "$(status "${CERT[@]}" -X DELETE "${GW}/v1/ssh-otp/creds/daily")" == "403" ]]
}

test_other_paths_forbidden() {
	[[ "$(status "${CERT[@]}" "${GW}/v1/sys/health")" == "403" ]]
}

test_unknown_host_closed() {
	[[ "$(status "${CERT[@]}" -H 'Host: evil.example' "${GW}/v1/ssh-otp/creds/daily")" == "000" ]]
}

printf "\n===== SSH gateway tests (bastion side, %s) =====\n\n" "$TARGET"
[[ -r "${CERT_DIR}/client.crt" && -r "${CERT_DIR}/client.key" ]] || {
	echo "Missing bastion certificate in ${CERT_DIR} (run make deploy first)" >&2
	exit 1
}
: "${CA_FILE}"
run_test "No client certificate → refused" test_no_cert_refused
run_test "Bastion cert + allowed path → reaches Vault" test_allowed_path_reaches_vault
run_test "Bastion cert + DELETE → 403 (P27)" test_method_restricted
run_test "Bastion cert + other path → 403" test_other_paths_forbidden
run_test "Bastion cert + unknown Host → closed (P28)" test_unknown_host_closed

TOTAL=$((PASS + FAIL))
printf "\n===== Results: %d PASS / %d FAIL (of %d) =====\n\n" "$PASS" "$FAIL" "$TOTAL"
[[ "$FAIL" -eq 0 ]]
