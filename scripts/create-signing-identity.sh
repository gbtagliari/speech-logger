#!/usr/bin/env bash
#
# Create a self-signed code-signing identity for local speech-logger builds.
#
# Why this exists: macOS keys the Input Monitoring (TCC) grant to the app's
# designated requirement. An ad-hoc signature's DR is the cdhash, which changes
# every rebuild and voids the grant. A stable identity's DR is `identifier + cert`,
# which survives rebuilds. See docs/adr/0005-stable-signing-identity-required.md.
#
# A self-signed cert is sufficient for a local, non-quarantined build (no
# notarization). The machine's Apple Development cert is revoked and must not be
# used (a revoked cert makes XProtect trash the app).
#
# Idempotent: re-running when the identity already exists is a no-op.
# Reversible: scripts/delete-signing-identity.sh removes it.
set -euo pipefail

# shellcheck source=scripts/_signing-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/_signing-env.sh"

# Throwaway password for the transient PKCS12 only. It never protects anything
# at rest (the .p12 is deleted on exit). An *empty* PKCS12 password makes Apple's
# importer fail "MAC verification failed", so a non-empty one is required.
P12_PASSWORD="speech-logger-import"

# The identity is self-signed, so it is untrusted (CSSMERR_TP_NOT_TRUSTED) and
# `find-identity -v` filters it out. That is expected and fine: codesign signs
# with it regardless, and a local non-quarantined build launches without a
# trusted chain (ADR-0005). So check for the certificate itself, not a "valid"
# identity.
if security find-certificate -c "${IDENTITY_CN}" "${KEYCHAIN}" >/dev/null 2>&1; then
  echo "code-signing identity '${IDENTITY_CN}' already present; nothing to do."
  security find-identity -p codesigning "${KEYCHAIN}" | grep -F "${IDENTITY_CN}" || true
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "generating self-signed code-signing certificate (CN=${IDENTITY_CN})..."

# Self-signed cert with the extensions codesign requires:
#   basicConstraints CA:FALSE     - a leaf, not a CA
#   keyUsage digitalSignature     - it signs
#   extendedKeyUsage codeSigning  - specifically for code (1.3.6.1.5.5.7.3.3)
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${WORKDIR}/key.pem" \
  -out "${WORKDIR}/cert.pem" \
  -days 3650 \
  -subj "/CN=${IDENTITY_CN}" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  2>/dev/null

# -legacy uses SHA1 MAC + legacy PBE algorithms. OpenSSL 3's modern defaults
# produce a PKCS12 that Apple's Security framework cannot import ("MAC
# verification failed"); -legacy output imports cleanly.
openssl pkcs12 -export -legacy \
  -inkey "${WORKDIR}/key.pem" \
  -in "${WORKDIR}/cert.pem" \
  -out "${WORKDIR}/identity.p12" \
  -passout "pass:${P12_PASSWORD}"

# -A allows any tool (codesign, xcodebuild) to use the private key without a
# per-signature "always allow" prompt, so no keychain password is needed here.
echo "importing into ${KEYCHAIN}..."
security import "${WORKDIR}/identity.p12" \
  -k "${KEYCHAIN}" \
  -P "${P12_PASSWORD}" \
  -A

echo
echo "done. code-signing identity (untrusted is expected and fine):"
security find-identity -p codesigning "${KEYCHAIN}" | grep -F "${IDENTITY_CN}"
