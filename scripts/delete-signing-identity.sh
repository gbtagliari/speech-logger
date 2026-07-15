#!/usr/bin/env bash
#
# Remove the self-signed speech-logger code-signing identity created by
# scripts/create-signing-identity.sh. Reverses that script cleanly.
set -euo pipefail

# shellcheck source=scripts/_signing-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_signing-env.sh"

if ! security find-identity -p codesigning -v "${KEYCHAIN}" | grep -qF "${IDENTITY_CN}"; then
  echo "no '${IDENTITY_CN}' identity found; nothing to delete."
  exit 0
fi

echo "deleting certificate '${IDENTITY_CN}' (and its private key) from ${KEYCHAIN}..."
# -t deletes the matching certificate; the associated key is removed with it.
security delete-certificate -c "${IDENTITY_CN}" -t "${KEYCHAIN}"
echo "done."
