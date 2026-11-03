#!/usr/bin/env bash
#
# build-macos-pkg.sh — package GateLink.app into an installer package.
#
# Produces dist/GateLink.pkg. Installer copies the app to /Applications and
# then installs the root tunnel helper for the logged-in user, so everything
# is set up with the one administrator prompt Installer already asks for.
#
# USAGE
#   ./scripts/build-macos-pkg.sh          # builds the .app first if needed
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/GateLink.app"
PKG="$DIST/GateLink.pkg"
STAGE="$DIST/pkg-stage"
PLIST="$DIST/pkg-components.plist"

if [ ! -d "$APP" ]; then
  echo "GateLink.app not found; building it first..."
  "$ROOT/scripts/build-macos-app.sh"
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "Staging package contents..."
rm -rf "$STAGE" "$PKG" "$PLIST"
mkdir -p "$STAGE/Applications"
# Drop extended attributes (e.g. quarantine) so they are not installed with the app.
ditto --norsrc --noextattr --noacl "$APP" "$STAGE/Applications/GateLink.app"

# Always install to /Applications. Without this, Installer "relocates" the
# update into any other copy with the same bundle id (e.g. dist/GateLink.app).
pkgbuild --analyze --root "$STAGE" "$PLIST" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$PLIST"

echo "Creating $PKG ..."
pkgbuild \
  --root "$STAGE" \
  --component-plist "$PLIST" \
  --scripts "$ROOT/scripts/pkg" \
  --identifier com.gatelink.app.pkg \
  --version "$VERSION" \
  --install-location / \
  "$PKG" >/dev/null

rm -rf "$STAGE" "$PLIST"

echo
echo "Built: $PKG (v$VERSION)"
echo "Install: double-click it; Installer sets up the app and the tunnel helper."
