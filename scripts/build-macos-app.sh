#!/usr/bin/env bash
#
# build-macos-app.sh — build GateLink.app with Xcode.
#
# Generates GateLink.xcodeproj from project.yml (XcodeGen), builds the Release
# configuration for this Mac's architecture, and copies the result to
# dist/GateLink.app. The OpenConnect engine staged in Engine/openconnect by
# scripts/bundle-openconnect.sh is embedded in Contents/Helpers.
#
# USAGE
#   ./scripts/build-macos-app.sh
#   GATELINK_VERSION=2.1.0 ./scripts/build-macos-app.sh
#   GATELINK_SIGN_IDENTITY="Apple Development: …" ./scripts/build-macos-app.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
DERIVED="$ROOT/build/DerivedData"
VERSION="${GATELINK_VERSION:-2.0.3}"
IDENTITY="${GATELINK_SIGN_IDENTITY:--}"
ARCH="${GATELINK_ARCH:-$(uname -m)}"

command -v xcodegen >/dev/null || { echo "ERROR: xcodegen not found (brew install xcodegen)." >&2; exit 1; }
[ -x "$ROOT/Engine/openconnect/openconnect" ] || \
  echo "warning: Engine/openconnect is empty; run scripts/bundle-openconnect.sh to embed the engine." >&2

cd "$ROOT"
xcodegen generate --quiet

APP="$DERIVED/Build/Products/Release/GateLink.app"
rm -rf "$APP"
xcodebuild -quiet \
  -project GateLink.xcodeproj \
  -scheme GateLink \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination "platform=macOS,arch=$ARCH" \
  ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  build

rm -rf "$DIST/GateLink.app"
mkdir -p "$DIST"
cp -R "$APP" "$DIST/GateLink.app"
codesign --verify --strict "$DIST/GateLink.app"

echo
echo "Built: $DIST/GateLink.app ($ARCH, v$VERSION)"
echo "Run it: open \"$DIST/GateLink.app\""
