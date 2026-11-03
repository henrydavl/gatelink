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
OPENSSL_VERSION=3.5.9
OPENCONNECT_VERSION=9.21
VPNC_COMMIT=ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101

# Pinned SHA-256 values (update all three together when bumping a version).
OPENSSL_SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
OPENCONNECT_SHA=5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58
VPNC_SHA=f0c4d936a382f07711263242699b5e2d85d1ace37136bb78785d352997c17742

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

fetch() { # url sha256 file
  local url="$1" sha="$2" file="$3"
  if [ ! -f "$file" ]; then
    echo "Downloading $url"
    curl -fSL --retry 3 --max-time 300 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  echo "$sha  $file" | shasum -a 256 -c - >/dev/null ||
    die "checksum mismatch: $file (delete it and retry)"
}

echo "== OpenSSL $OPENSSL_VERSION ($SSL_TARGET, min macOS $TARGET)"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
  "$OPENSSL_SHA" "openssl-$OPENSSL_VERSION.tar.gz"
rm -rf openssl-src
mkdir openssl-src
tar xzf "openssl-$OPENSSL_VERSION.tar.gz" -C openssl-src --strip-components=1
(
  cd openssl-src
  ./Configure "$SSL_TARGET" shared no-tests no-docs \
    --prefix="$PREFIX" --openssldir="$PREFIX/etc/ssl" \
    -mmacosx-version-min="$TARGET"
  make -s -j"$(sysctl -n hw.ncpu)"
  make -s install_sw
)

echo "== OpenConnect $OPENCONNECT_VERSION"
fetch "https://www.infradead.org/openconnect/download/openconnect-$OPENCONNECT_VERSION.tar.gz" \
  "$OPENCONNECT_SHA" "openconnect-$OPENCONNECT_VERSION.tar.gz"
rm -rf openconnect-src
mkdir openconnect-src
tar xzf "openconnect-$OPENCONNECT_VERSION.tar.gz" -C openconnect-src --strip-components=1
# OpenSSL 3 refuses gateways without secure renegotiation (e.g. vpn.bri.co.id);
# the patch allows them, as GnuTLS builds do, without --allow-insecure-crypto.
patch -s -d openconnect-src -p1 < "$SCRIPT_DIR/patches/openconnect-legacy-renegotiation.patch"
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
