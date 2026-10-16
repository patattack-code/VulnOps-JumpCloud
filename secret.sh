#!/usr/bin/env bash
# secret.sh — fetch one secret from the OS credential store and print it to stdout.
# Usage: secret.sh <name>        e.g. secret.sh jumpcloud-api-key
#
# Lookup order:
#   1. 1Password CLI, if VULNOPS_OP_VAULT is set   -> op://$VULNOPS_OP_VAULT/<name>/credential
#   2. macOS Keychain                              -> service "vulnops", account <name>
#   3. Linux Secret Service (GNOME Keyring/KWallet) -> service "vulnops", account <name>
#
# Nothing is cached, logged, or written to disk. Exits non-zero (with a message
# on stderr only) if the secret is missing.
set -euo pipefail

name="${1:?usage: secret.sh <name>}"
service="vulnops"

# Allow only simple names so the value can't be used to inject arguments.
if [[ ! "$name" =~ ^[a-z0-9-]+$ ]]; then
  echo "secret.sh: invalid secret name" >&2
  exit 2
fi

if [[ -n "${VULNOPS_OP_VAULT:-}" ]] && command -v op >/dev/null 2>&1; then
  exec op read --no-newline "op://${VULNOPS_OP_VAULT}/${name}/credential"
fi

case "$(uname -s)" in
  Darwin)
    exec security find-generic-password -s "$service" -a "$name" -w
    ;;
  Linux)
    if command -v secret-tool >/dev/null 2>&1; then
      value="$(secret-tool lookup service "$service" account "$name")" || true
      if [[ -n "$value" ]]; then
        printf '%s' "$value"
        exit 0
      fi
    fi
    ;;
esac

echo "secret.sh: secret '$name' not found in any credential store" >&2
exit 1
