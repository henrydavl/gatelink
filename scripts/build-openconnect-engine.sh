#!/usr/bin/env bash
#
# build-openconnect-engine.sh — build the bundled OpenConnect engine from
# pinned sources with a fixed macOS deployment target.
#
# Why not Homebrew? GitHub-hosted macOS runners are macOS 15/26 now, and the
# Homebrew bottle they pour is built for that OS (minos 15/26). GateLink still
# supports macOS 14, so the engine is compiled here with
# -mmacosx-version-min=14.0. OpenSSL is built shared (also minos 14) and
# OpenConnect links it; bundle-openconnect.sh then copies the dylibs into the
# app and rewrites their load paths to @loader_path.
#
# OpenConnect is built against OpenSSL instead of GnuTLS so the build does not
# depend on Homebrew's GnuTLS/p11-kit stacks (which would drag in minos 15
# dylibs). The GlobalProtect protocol and DTLS/ESP support are identical.
#
# Output (default prefix: $RUNNER_TEMP/gatelink-engine):
#   sbin/openconnect
#   lib/libopenconnect.5.dylib
#   lib/libssl.3.dylib
#   lib/libcrypto.3.dylib
#   etc/vpnc/vpnc-script
#
# USAGE
#   ./scripts/build-openconnect-engine.sh
#   GATELINK_ENGINE_PREFIX=/tmp/engine ./scripts/build-openconnect-engine.sh
#
set -euo pipefail

TARGET=14.0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=engine-sources.sh
. "$SCRIPT_DIR/engine-sources.sh"

BASE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
PREFIX="${GATELINK_ENGINE_PREFIX:-${BASE%/}/gatelink-engine}"
BUILD="${GATELINK_ENGINE_BUILD_DIR:-${BASE%/}/gatelink-engine-build}"

die() { echo "build-openconnect-engine: $*" >&2; exit 1; }

case "$(uname -m)" in
  arm64)  SSL_TARGET=darwin64-arm64-cc ;;
  x86_64) SSL_TARGET=darwin64-x86_64-cc ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

command -v xcrun >/dev/null || die "Xcode command line tools are required"
command -v pkg-config >/dev/null || die "pkg-config is required (brew install pkg-config)"
SDK="$(xcrun --show-sdk-path)"

mkdir -p "$BUILD" "$PREFIX"
cd "$BUILD"

echo "== OpenSSL $OPENSSL_VERSION ($SSL_TARGET, min macOS $TARGET)"
unpack_openssl
(
  cd openssl-src
  ./Configure "$SSL_TARGET" shared no-tests no-docs \
    --prefix="$PREFIX" --openssldir="$PREFIX/etc/ssl" \
    -mmacosx-version-min="$TARGET"
  make -s -j"$(sysctl -n hw.ncpu)"
  make -s install_sw
)

echo "== OpenConnect $OPENCONNECT_VERSION"
unpack_openconnect
mkdir -p "$BUILD/empty-pkgconfig"

(
  cd openconnect-src
  # Keep pkg-config away from Homebrew: its p11-kit would otherwise be linked
  # into the binary and pull macOS 15 dylibs back in. libxml2 comes from the SDK.
  PKG_CONFIG_LIBDIR="$BUILD/empty-pkgconfig" PKG_CONFIG_PATH= \
  LIBXML2_CFLAGS="-I$SDK/usr/include/libxml2" LIBXML2_LIBS="-lxml2" \
  OPENSSL_CFLAGS="-I$PREFIX/include" OPENSSL_LIBS="-L$PREFIX/lib -lssl -lcrypto" \
  CFLAGS="-mmacosx-version-min=$TARGET -O2" \
  LDFLAGS="-mmacosx-version-min=$TARGET" \
  ./configure --prefix="$PREFIX" \
    --without-gnutls --with-openssl=yes \
    --with-vpnc-script=/usr/local/libexec/gatelink/vpnc-script \
    --without-libproxy --without-stoken --without-libpcsclite \
    --without-libpskc --without-gssapi --without-lz4 \
    --disable-nls --disable-docs
  make -s -j"$(sysctl -n hw.ncpu)"
  make -s install
)

echo "== vpnc-script"
fetch "https://gitlab.com/openconnect/vpnc-scripts/-/raw/$VPNC_COMMIT/vpnc-script" \
  "$VPNC_SHA" "vpnc-script"
install -d -m 0755 "$PREFIX/etc/vpnc"
install -m 0755 "$BUILD/vpnc-script" "$PREFIX/etc/vpnc/vpnc-script"

echo "== Verify deployment target"
fail=0
for f in "$PREFIX/sbin/openconnect" "$PREFIX"/lib/*.dylib; do
  [ -f "$f" ] || continue
  v=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')
  if [ -z "$v" ]; then
    echo "ERROR: cannot read minos for $f"
    fail=1
    continue
  fi
  echo "  $(basename "$f") minos=$v"
  lower=$(printf '%s\n%s\n' "$v" "$TARGET" | sort -t. -k1,1n -k2,2n | head -1)
  if [ "$lower" != "$v" ]; then
    echo "ERROR: $f requires macOS $v (target is $TARGET)"
    fail=1
  fi
done
[ "$fail" -eq 0 ] || die "engine contains binaries newer than macOS $TARGET"

echo
"$PREFIX/sbin/openconnect" --version | head -1
echo "Engine prefix: $PREFIX"
