#!/bin/bash
#
# sign-release.sh — sign a macOS DMG for GateLink auto-update.
#
# The private key is NOT in this repository. Generate it once, store it in a
# password manager / GitHub Actions secret. Released .NET builds (v0.1.x) pin
# the public key and verify this signature before auto-updating, so signed
# releases let them upgrade to the Swift app in place.
#
# USAGE
#   ./scripts/sign-release.sh dist/GateLink.dmg /path/to/gatelink-release.key
#
set -euo pipefail

DMG="${1:-}"
KEY="${2:-}"

if [[ -z "${DMG}" || -z "${KEY}" || ! -f "${DMG}" || ! -f "${KEY}" ]]; then
    echo "usage: sign-release.sh <GateLink.dmg> <private-key.pem>" >&2
    exit 2
fi

PUB="$(mktemp)"
trap '/bin/rm -f "${PUB}"' EXIT

echo "Signing ${DMG} ..."
openssl dgst -sha256 -sign "${KEY}" -out "${DMG}.sig" "${DMG}"

openssl rsa -in "${KEY}" -pubout -out "${PUB}" 2>/dev/null
openssl dgst -sha256 -verify "${PUB}" -signature "${DMG}.sig" "${DMG}" >/dev/null

shasum -a 256 "${DMG}" | awk '{print $1}' > "${DMG}.sha256"

echo "Wrote ${DMG}.sig and ${DMG}.sha256"
