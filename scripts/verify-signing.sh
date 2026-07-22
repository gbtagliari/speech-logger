#!/usr/bin/env bash
#
# Verify the signing acceptance criteria for issue #14, so the "verified" claim
# in the ticket is reproducible instead of a one-off manual check:
#
#   1. The build is signed with the stable identity, not ad-hoc.
#   2. App Sandbox is OFF.
#   3. A rebuild does not change the designated requirement (ADR-0005) — the
#      property the Input Monitoring (TCC) grant depends on.
#
# Two clean builds, then diff `codesign -d --requirements -`. Exits non-zero on
# any failure so it can gate CI later.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/_signing-env.sh
source "scripts/_signing-env.sh"

WORKSPACE="SpeechLogger.xcworkspace"
SCHEME="SpeechLogger"
DERIVED="$(mktemp -d)"
trap 'rm -rf "${DERIVED}"' EXIT
# `CONFIGURATION_BUILD_DIR` in Project.swift redirects the products here, out of
# the derived data directory, so the temp `-derivedDataPath` holds intermediates
# only. Both builds below therefore overwrite this same path.
PRODUCTS="builds/Debug"
APP="${PRODUCTS}/SpeechLogger.app"

if [ ! -d "${WORKSPACE}" ]; then
  echo "workspace not found; run 'tuist generate' first." >&2
  exit 1
fi

clean_build() {
  rm -rf "${DERIVED:?}/Build" "${PRODUCTS:?}"
  xcodebuild build \
    -workspace "${WORKSPACE}" -scheme "${SCHEME}" \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED}" >/dev/null 2>&1
}

designated_requirement() {
  codesign -d --requirements - "${APP}" 2>&1 | sed -n 's/^designated => //p'
}

echo "build #1..."
clean_build
DR1="$(designated_requirement)"

echo "build #2..."
clean_build
DR2="$(designated_requirement)"

fail=0

echo
echo "designated requirement:"
echo "  ${DR1}"
if [ "${DR1}" = "${DR2}" ]; then
  echo "  [ok] stable across rebuild"
else
  echo "  [FAIL] changed across rebuild:" >&2
  echo "         #2: ${DR2}" >&2
  fail=1
fi
case "${DR1}" in
  *cdhash*) echo "  [FAIL] ad-hoc signature (cdhash DR) — not a stable identity" >&2; fail=1 ;;
  *"identifier \"${BUNDLE_ID}\""*"certificate leaf"*) echo "  [ok] identity-based DR (identifier + cert)" ;;
  *) echo "  [FAIL] unexpected DR shape" >&2; fail=1 ;;
esac

echo
echo "signing authority:"
AUTHORITY="$(codesign -dvv "${APP}" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [ "${AUTHORITY}" = "${IDENTITY_CN}" ]; then
  echo "  [ok] ${AUTHORITY}"
else
  echo "  [FAIL] expected '${IDENTITY_CN}', got '${AUTHORITY:-<none>}'" >&2
  fail=1
fi

echo
echo "app sandbox:"
# The entitlement key contains dots, which plutil/PlistBuddy treat as key-path
# separators, so read the raw XML: assert the key is present and set to <false/>.
ENTITLEMENTS_XML="$(codesign -d --entitlements - --xml "${APP}" 2>/dev/null)"
if grep -A1 'com\.apple\.security\.app-sandbox' <<<"${ENTITLEMENTS_XML}" | grep -q '<false/>'; then
  echo "  [ok] OFF (entitlement present and false)"
elif grep -A1 'com\.apple\.security\.app-sandbox' <<<"${ENTITLEMENTS_XML}" | grep -q '<true/>'; then
  echo "  [FAIL] sandbox is ON" >&2
  fail=1
else
  echo "  [FAIL] app-sandbox entitlement missing — entitlements file not applied?" >&2
  fail=1
fi

echo
if [ "${fail}" -eq 0 ]; then
  echo "all signing checks passed."
else
  echo "signing checks FAILED." >&2
fi
exit "${fail}"
