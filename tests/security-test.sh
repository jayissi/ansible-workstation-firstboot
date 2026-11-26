#!/usr/bin/env bash
# =============================================================================
# Nginx / Vault Security Regression Tests (run ON the workstation as root)
# Runs on the target VM via:  make security-test
# Bastion-side gateway tests (need the bastion client cert) live in
# tests/bastion-test.sh and run from the controller via `make validate`.
# Exit 0 = all pass, exit 1 = any fail
# =============================================================================
# Test functions are invoked indirectly via run_test "<name>" <fn>; the
# linter cannot follow that, so SC2329 ("function never invoked"; SC2317
# on the older ShellCheck pinned in pre-commit) is a false positive here.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CA_CERT="/etc/nginx/certs/root.crt"
VAULT_HOST="${VAULT_HOST:-vault.internal}"
STATUS_HOST="${STATUS_HOST:-status.${VAULT_HOST}}"
SSH_GW_HOST="${SSH_GW_HOST:-vault-ssh-gateway.internal}"
LISTEN_IP="127.0.0.1"
HTTPS_PORT="443"
SSH_GW_PORT="8443"
VAULT_API_PORT="8200"
VAULT_CA="/etc/vault.d/certs/root.crt"
# Real VaultPass client certificate (OU=Workstation Auth): valid CA, wrong OU
# for the SSH gateway, and the cert an attacker would replay in T-01.
CLIENT_CERT="/etc/vault.d/certs/client.crt"
CLIENT_KEY="/etc/vault.d/certs/client.key"

# ---------------------------------------------------------------------------
# Counters  (use PASS=$((PASS + 1)), NOT ((PASS++)) — the latter exits
#            under set -e when the variable is 0 because 0++ evaluates falsy)
# ---------------------------------------------------------------------------
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Test runner — each test function is called inside an `if`, which inhibits
# set -e for the entire function body.  Individual curl/grep failures inside
# the function will NOT terminate the script.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Helpers
#   get_status — returns the HTTP status code (or "000" on connection error).
#     curl -w '%{http_code}' already outputs "000" when it cannot connect,
#     so we do NOT append "|| echo 000" (that would double it to "000000").
#   get_headers — returns raw response headers.
# ---------------------------------------------------------------------------
get_status() {
	local url="$1"
	shift
	curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "$url"
}

get_headers() {
	local url="$1"
	shift
	curl -s -I --max-time 5 "$@" "$url"
}

# =============================================================================
# NEGATIVE tests — security controls must block these
# =============================================================================

test_unknown_host() {
	local http_code
	http_code=$(get_status "https://unknown.example.com/" \
		--cacert "$CA_CERT" \
		--resolve "unknown.example.com:${HTTPS_PORT}:${LISTEN_IP}")
	[[ "$http_code" == "000" ]]
}

test_tls11_rejected() {
	local http_code
	http_code=$(get_status "https://${VAULT_HOST}/" \
		--cacert "$CA_CERT" \
		--resolve "${VAULT_HOST}:${HTTPS_PORT}:${LISTEN_IP}" \
		--tlsv1.1 --tls-max 1.1)
	[[ "$http_code" == "000" ]]
}

# KNOWN_ISSUES P26: the gateway requires a client certificate.
test_ssh_gw_requires_client_cert() {
	local http_code
	http_code=$(get_status "https://${SSH_GW_HOST}:${SSH_GW_PORT}/v1/ssh-otp/creds/daily" \
		-k -X PUT \
		--resolve "${SSH_GW_HOST}:${SSH_GW_PORT}:${LISTEN_IP}")
	[[ "$http_code" == "400" ]] || [[ "$http_code" == "000" ]]
}

# A valid certificate from the same CA but without the bastion OU is refused.
test_ssh_gw_rejects_wrong_ou() {
	local http_code
	http_code=$(get_status "https://${SSH_GW_HOST}:${SSH_GW_PORT}/v1/ssh-otp/creds/daily" \
		-k -X PUT --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
		--resolve "${SSH_GW_HOST}:${SSH_GW_PORT}:${LISTEN_IP}")
	[[ "$http_code" == "403" ]]
}

# T-01 (review finding E-02 / CAB Rev 2 F1): a local process sends the REAL
# VaultPass public certificate in X-Client-Cert straight to Vault on 8200.
# Port 8200 must not trust forwarded headers, so no token may be issued.
test_vault_8200_ignores_forged_cert_header() {
	local enc body
	enc=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(open(sys.argv[1]).read(), safe=""))' "$CLIENT_CERT")
	body=$(curl -s --max-time 5 --cacert "$VAULT_CA" \
		--resolve "${VAULT_HOST}:${VAULT_API_PORT}:${LISTEN_IP}" \
		-H "X-Forwarded-For: 127.0.0.1" \
		-H "X-Client-Cert: ${enc}" \
		-X POST "https://${VAULT_HOST}:${VAULT_API_PORT}/v1/auth/cert/login")
	! echo "$body" | grep -q '"client_token"'
}

# KNOWN_ISSUES P32: Vault responses must never be cached by browsers.
test_cache_control_no_store() {
	get_headers "https://${VAULT_HOST}/v1/sys/health" \
		--cacert "$CA_CERT" \
		--resolve "${VAULT_HOST}:${HTTPS_PORT}:${LISTEN_IP}" | grep -qi '^cache-control:.*no-store'
}

# Review finding E-07: nothing listens on plaintext :80.
test_no_plaintext_http() {
	local http_code
	http_code=$(get_status "http://${LISTEN_IP}:80/")
	[[ "$http_code" == "000" ]]
}

test_security_headers() {
	local headers
	headers=$(get_headers "https://${VAULT_HOST}/" \
		--cacert "$CA_CERT" \
		--resolve "${VAULT_HOST}:${HTTPS_PORT}:${LISTEN_IP}")
	echo "$headers" | grep -qi "Strict-Transport-Security" &&
		echo "$headers" | grep -qi "X-Frame-Options" &&
		echo "$headers" | grep -qi "X-Content-Type-Options"
}

test_forged_client_cert() {
	local http_code
	http_code=$(get_status "https://${VAULT_HOST}/v1/auth/cert/login" \
		--cacert "$CA_CERT" \
		--resolve "${VAULT_HOST}:${HTTPS_PORT}:${LISTEN_IP}" \
		-H "X-Client-Cert: FORGED_CERT_DATA" \
		-X POST)
	[[ "$http_code" != "200" ]]
}

# =============================================================================
# POSITIVE tests — legitimate requests must succeed
# =============================================================================

test_health_endpoint() {
	local http_code
	http_code=$(get_status "https://${STATUS_HOST}/" \
		--cacert "$CA_CERT" \
		--resolve "${STATUS_HOST}:${HTTPS_PORT}:${LISTEN_IP}")
	[[ "$http_code" == "200" ]]
}

test_vault_ui() {
	local http_code
	http_code=$(get_status "https://${VAULT_HOST}/ui/" \
		--cacert "$CA_CERT" \
		--resolve "${VAULT_HOST}:${HTTPS_PORT}:${LISTEN_IP}")
	[[ "$http_code" == "200" ]] || [[ "$http_code" == "307" ]]
}

# KNOWN_ISSUES P29: CSP violation reports are accepted and logged as JSON.
test_csp_report_endpoint() {
	local http_code marker
	marker="csp-selftest-$$"
	http_code=$(get_status "https://${VAULT_HOST}/csp-report" \
		--cacert "$CA_CERT" \
		--resolve "${VAULT_HOST}:${HTTPS_PORT}:${LISTEN_IP}" \
		-X POST -H 'Content-Type: application/csp-report' \
		--data "{\"csp-report\":{\"document-uri\":\"${marker}\"}}")
	[[ "$http_code" == "204" ]] && sleep 1 && grep -q "$marker" /var/log/nginx/csp-report.log
}

# KNOWN_ISSUES P31: access log lines are valid JSON.
test_access_log_is_json() {
	get_status "https://${VAULT_HOST}/v1/sys/health" \
		--cacert "$CA_CERT" \
		--resolve "${VAULT_HOST}:${HTTPS_PORT}:${LISTEN_IP}" >/dev/null
	sleep 1
	tail -1 /var/log/nginx/vault-mtls-access.log |
		python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert "cert_fingerprint" in d and "uri" in d'
}

# =============================================================================
# Run all tests
# =============================================================================
printf "\n===== Nginx Security Regression Tests =====\n\n"

printf '%s\n' "--- Negative tests (security controls must block) ---"
run_test "Unknown Host header → connection closed" test_unknown_host
run_test "TLS 1.1 → rejected" test_tls11_rejected
run_test "Plain HTTP :80 → nothing listening" test_no_plaintext_http
run_test "SSH gateway without client cert → refused" test_ssh_gw_requires_client_cert
run_test "SSH gateway with non-bastion cert → 403" test_ssh_gw_rejects_wrong_ou
run_test "Security headers present (HSTS, XFO, XCTO)" test_security_headers
run_test "Cache-Control: no-store on Vault responses" test_cache_control_no_store
run_test "Forged X-Client-Cert via Nginx → not authenticated" test_forged_client_cert
run_test "T-01 forged X-Client-Cert direct to :8200 → no token" test_vault_8200_ignores_forged_cert_header

printf '\n%s\n' "--- Positive tests (legitimate requests must succeed) ---"
run_test "Health endpoint (${STATUS_HOST}) → 200" test_health_endpoint
run_test "Vault UI accessible → 200 or 307" test_vault_ui
run_test "CSP report endpoint → 204 + logged" test_csp_report_endpoint
run_test "Access log is structured JSON" test_access_log_is_json

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((PASS + FAIL))
printf "\n===== Results: %d PASS / %d FAIL (of %d) =====\n\n" "$PASS" "$FAIL" "$TOTAL"

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
