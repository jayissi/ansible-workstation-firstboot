#!/usr/bin/env bash
# =============================================================================
# Nginx Security Regression Tests
# Runs on the target VM via:  make security-test
# Exit 0 = all pass, exit 1 = any fail
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CA_CERT="/etc/nginx/certs/root.crt"
VAULT_HOST="vault.local"
STATUS_HOST="status.vault.local"
SSH_GW_HOST="vault-ssh-gateway.local"
LISTEN_IP="127.0.0.1"
HTTPS_PORT="443"
SSH_GW_PORT="8443"

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
    local url="$1"; shift
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "$url"
}

get_headers() {
    local url="$1"; shift
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

test_ssh_gw_blocked_path() {
    local http_code
    http_code=$(get_status "https://${SSH_GW_HOST}:${SSH_GW_PORT}/v1/sys/health" \
        -k \
        --resolve "${SSH_GW_HOST}:${SSH_GW_PORT}:${LISTEN_IP}")
    [[ "$http_code" == "403" ]]
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

test_ssh_gw_allowed_path() {
    local body
    body=$(curl -s --max-time 5 -k \
        --resolve "${SSH_GW_HOST}:${SSH_GW_PORT}:${LISTEN_IP}" \
        "https://${SSH_GW_HOST}:${SSH_GW_PORT}/v1/ssh-otp/creds/test")
    echo "$body" | grep -q '"errors"'
}

# =============================================================================
# Run all tests
# =============================================================================
printf "\n===== Nginx Security Regression Tests =====\n\n"

printf '%s\n' "--- Negative tests (security controls must block) ---"
run_test "Unknown Host header → connection closed"       test_unknown_host
run_test "TLS 1.1 → rejected"                            test_tls11_rejected
run_test "SSH gateway /v1/sys/health → 403"              test_ssh_gw_blocked_path
run_test "Security headers present (HSTS, XFO, XCTO)"   test_security_headers
run_test "Forged X-Client-Cert → not authenticated"      test_forged_client_cert

printf '\n%s\n' "--- Positive tests (legitimate requests must succeed) ---"
run_test "Health endpoint (status.vault.local) → 200"    test_health_endpoint
run_test "Vault UI accessible → 200 or 307"              test_vault_ui
run_test "SSH gateway allowed path → non-403"            test_ssh_gw_allowed_path

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((PASS + FAIL))
printf "\n===== Results: %d PASS / %d FAIL (of %d) =====\n\n" "$PASS" "$FAIL" "$TOTAL"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
