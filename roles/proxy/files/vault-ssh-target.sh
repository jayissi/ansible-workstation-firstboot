#!/bin/bash
# vault-ssh-target -- OTP SSH to the hardened workstation via the credential
# gateway (port 8443). Run this on the BASTION.
#
# The gateway requires mutual TLS (KNOWN_ISSUES P26): a client certificate
# with OU "Bastion Gateway" issued by `make deploy` into the controller's
# gitignored .bastion/ directory. Copy client.crt + client.key to
# ~/.config/vault-bastion/ on the bastion (or set VAULT_CLIENT_CERT and
# VAULT_CLIENT_KEY explicitly).
#
# Environment:
#   VAULT_GATEWAY   workstation IP or hostname (default: first local IP,
#                   which is only correct when run ON the workstation)
#   VAULT_ADDR      full gateway URL (overrides VAULT_GATEWAY)
#   VAULT_CACERT    CA bundle that trusts the Vault Root CA
set -euo pipefail

export VAULT_ADDR="${VAULT_ADDR:-https://${VAULT_GATEWAY:-$(hostname -I | awk '{print $1}')}:8443}"
export VAULT_CACERT="${VAULT_CACERT:-/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem}"

cert_dir="${VAULT_BASTION_CERT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/vault-bastion}"
if [[ -z "${VAULT_CLIENT_CERT:-}" && -r "${cert_dir}/client.crt" && -r "${cert_dir}/client.key" ]]; then
	export VAULT_CLIENT_CERT="${cert_dir}/client.crt"
	export VAULT_CLIENT_KEY="${cert_dir}/client.key"
fi
if [[ -z "${VAULT_CLIENT_CERT:-}" ]]; then
	echo "vault-ssh-target: no bastion client certificate found in ${cert_dir}" >&2
	echo "  The SSH gateway requires mTLS; see docs/OPERATIONS.md (Bastion Enrollment)." >&2
	exit 1
fi

exec vault ssh -mode=otp -role=daily -mount-point=ssh-otp "$@"
