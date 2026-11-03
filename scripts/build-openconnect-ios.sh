#!/usr/bin/env bash
#
# build-openconnect-ios.sh — build OpenSSL and libopenconnect as static arm64
# libraries for the iOS Packet Tunnel extension, from the same pinned and
# patched sources as the macOS engine. iOS 18.4 is the minimum because
# OpenConnect calls strchrnul.
#
# iOS apps cannot run the openconnect binary, so the extension links the
# library and drives it in-process; libxml2 and zlib come from the iOS SDK.
#
# Output: Engine/ios/{include,lib} (libopenconnect.a, libssl.a, libcrypto.a)
#
# USAGE
#   ./scripts/build-openconnect-ios.sh
#
set -euo pipefail

TARGET=18.4
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=engine-sources.sh
. "$SCRIPT_DIR/engine-sources.sh"

PREFIX="$ROOT/Engine/ios"
BUILD="${TMPDIR:-/tmp}"
BUILD="${BUILD%/}/gatelink-engine-ios-build"

die() { echo "build-openconnect-ios: $*" >&2; exit 1; }

command -v xcrun >/dev/null || die "Xcode is required"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$TARGET"
JOBS="$(sysctl -n hw.ncpu)"

rm -rf "$PREFIX"
mkdir -p "$BUILD" "$PREFIX"
cd "$BUILD"

echo "== OpenSSL $OPENSSL_VERSION (iOS arm64, min $TARGET)"
unpack_openssl
(
  cd openssl-src
  ./Configure ios64-xcrun no-shared no-tests no-docs no-apps \
    --prefix="$PREFIX" --openssldir=/var/empty \
    -miphoneos-version-min="$TARGET"
  make -s -j"$JOBS"
  make -s install_sw
)

echo "== libopenconnect $OPENCONNECT_VERSION"
unpack_openconnect
mkdir -p "$BUILD/empty-pkgconfig"
(
  cd openconnect-src
  PKG_CONFIG_LIBDIR="$BUILD/empty-pkgconfig" PKG_CONFIG_PATH= \
  LIBXML2_CFLAGS="-I$SDK/usr/include/libxml2" LIBXML2_LIBS="-lxml2" \
  OPENSSL_CFLAGS="-I$PREFIX/include" OPENSSL_LIBS="-L$PREFIX/lib -lssl -lcrypto" \
  CC="$CC" CFLAGS="$FLAGS -O2" LDFLAGS="$FLAGS" \
  ./configure --host=aarch64-apple-darwin --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --without-gnutls --with-openssl=yes \
    --with-vpnc-script=/dev/null \
    --without-libproxy --without-stoken --without-libpcsclite \
    --without-libpskc --without-gssapi --without-lz4 \
    --disable-nls --disable-docs
  make -s -j"$JOBS" libopenconnect.la
  install -d "$PREFIX/include" "$PREFIX/lib"
  install -m 0644 openconnect.h "$PREFIX/include/openconnect.h"
  install -m 0644 .libs/libopenconnect.a "$PREFIX/lib/libopenconnect.a"
)

echo "== Verify"
for lib in libopenconnect libssl libcrypto; do
  f="$PREFIX/lib/$lib.a"
  [ -f "$f" ] || die "missing $f"
  echo "  $lib.a $(lipo -archs "$f")"
done
echo "Engine prefix: $PREFIX"
