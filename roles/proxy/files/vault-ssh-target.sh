#!/bin/bash
# vault-ssh-target -- OTP SSH to the hardened workstation via the credential gateway
set -euo pipefail
export VAULT_ADDR="${VAULT_ADDR:-https://$(hostname -I | awk '{print $1}'):8443}"
export VAULT_CACERT="${VAULT_CACERT:-/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem}"
exec vault ssh -mode=otp -role=daily -mount-point=ssh-otp "$@"
