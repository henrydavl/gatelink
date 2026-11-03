#!/usr/bin/env bash
#
# build-openconnect-android.sh — build libopenconnect with its Java (JNI)
# bindings for the Android app, from the same pinned and patched sources as
# the macOS engine. OpenSSL and libxml2 are built with -fPIC and
# linked in statically, so the app ships one library.
#
# Output (gitignored):
#   android/app/src/main/jniLibs/arm64-v8a/libopenconnect.so
#   android/app/src/main/java/org/infradead/libopenconnect/LibOpenConnect.java
#
# USAGE
#   ./scripts/build-openconnect-android.sh
#   ANDROID_NDK_HOME=/path/to/ndk ./scripts/build-openconnect-android.sh
#
set -euo pipefail

API=28           # bionic has iconv from API 28
ABI=arm64-v8a
HOST=aarch64-linux-android
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=engine-sources.sh
. "$SCRIPT_DIR/engine-sources.sh"

die() { echo "build-openconnect-android: $*" >&2; exit 1; }

NDK="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/29.0.14206865}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
[ -x "$TOOLCHAIN/bin/clang" ] || die "Android NDK not found at $NDK (set ANDROID_NDK_HOME)"
SYSROOT="$TOOLCHAIN/sysroot"
export PATH="$TOOLCHAIN/bin:$PATH"
export CC="$HOST$API-clang" AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip
JOBS="$(sysctl -n hw.ncpu)"

BUILD="${TMPDIR:-/tmp}"
BUILD="${BUILD%/}/gatelink-engine-android-build"
PREFIX="$BUILD/prefix"
APP="$ROOT/android/app/src/main"

rm -rf "$PREFIX"
mkdir -p "$BUILD" "$PREFIX"
cd "$BUILD"

echo "== OpenSSL $OPENSSL_VERSION ($ABI, API $API)"
unpack_openssl
(
  cd openssl-src
  ANDROID_NDK_ROOT="$NDK" ./Configure android-arm64 no-shared no-tests no-docs no-apps \
    -D__ANDROID_API__="$API" -fPIC --prefix="$PREFIX" --openssldir=/dev/null
  make -s -j"$JOBS"
  make -s install_sw
)

echo "== libxml2 $LIBXML2_VERSION"
unpack_libxml2
(
  cd libxml2-src
  CFLAGS="-O2 -fPIC" ./configure --host="$HOST" --prefix="$PREFIX" --enable-static --disable-shared \
    --without-python --without-lzma --without-zlib --without-http --without-ftp \
    --without-modules --without-debug
  make -s -j"$JOBS"
  make -s install
)

echo "== libopenconnect $OPENCONNECT_VERSION (with Java bindings)"
unpack_openconnect
mkdir -p "$BUILD/empty-pkgconfig"
(
  cd openconnect-src
  PKG_CONFIG_LIBDIR="$BUILD/empty-pkgconfig" PKG_CONFIG_PATH= \
  LIBXML2_CFLAGS="-I$PREFIX/include/libxml2" LIBXML2_LIBS="-L$PREFIX/lib -lxml2" \
  OPENSSL_CFLAGS="-I$PREFIX/include" OPENSSL_LIBS="-L$PREFIX/lib -lssl -lcrypto" \
  CFLAGS="-O2 -fPIC" \
  ./configure --host="$HOST" --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --without-gnutls --with-openssl=yes \
    --with-java="$SYSROOT/usr/include" --enable-jni-standalone \
    --with-vpnc-script=/dev/null \
    --without-libproxy --without-stoken --without-libpcsclite \
    --without-libpskc --without-gssapi --without-lz4 \
    --disable-nls --disable-docs
  make -s -j"$JOBS" libopenconnect.la
)

echo "== Link libopenconnect.so"
mkdir -p "$APP/jniLibs/$ABI" "$APP/java/org/infradead/libopenconnect"
# One self-contained library; 16 KB pages for Android 15+ devices.
"$CC" -shared -o "$APP/jniLibs/$ABI/libopenconnect.so" \
  -Wl,-soname,libopenconnect.so -Wl,-z,max-page-size=16384 -Wl,--no-undefined \
  -Wl,--whole-archive openconnect-src/.libs/libopenconnect.a -Wl,--no-whole-archive \
  "$PREFIX/lib/libxml2.a" "$PREFIX/lib/libssl.a" "$PREFIX/lib/libcrypto.a" \
  -lz -llog -lm
"$STRIP" --strip-unneeded "$APP/jniLibs/$ABI/libopenconnect.so"
install -m 0644 openconnect-src/java/src/org/infradead/libopenconnect/LibOpenConnect.java \
  "$APP/java/org/infradead/libopenconnect/LibOpenConnect.java"

echo "== Verify"
llvm-nm -D --defined-only "$APP/jniLibs/$ABI/libopenconnect.so" | grep -c " T Java_org_infradead_libopenconnect" |
  { read -r n; [ "$n" -gt 50 ] || die "JNI symbols missing ($n)"; echo "  $n JNI entry points"; }
llvm-readelf -d "$APP/jniLibs/$ABI/libopenconnect.so" | grep NEEDED | sed 's/^/ /'
echo "Built: $APP/jniLibs/$ABI/libopenconnect.so"
