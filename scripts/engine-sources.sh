# engine-sources.sh — pinned OpenSSL / OpenConnect / vpnc-script / libxml2
# sources, shared by the macOS (build-openconnect-engine.sh) and Android
# (build-openconnect-android.sh) engine builds. Source it after setting
# SCRIPT_DIR and defining die(); run the unpack_* functions in the build dir.

OPENSSL_VERSION=3.5.9
OPENCONNECT_VERSION=9.21
VPNC_COMMIT=ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101
# Only Android needs it: the macOS SDK ships libxml2.
LIBXML2_VERSION=2.13.9

# Pinned SHA-256 values (update all three together when bumping a version).
OPENSSL_SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
OPENCONNECT_SHA=5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58
VPNC_SHA=f0c4d936a382f07711263242699b5e2d85d1ace37136bb78785d352997c17742
LIBXML2_SHA=a2c9ae7b770da34860050c309f903221c67830c86e4a7e760692b803df95143a

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

# Fresh openssl-src/ from the pinned tarball.
unpack_openssl() {
  fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
    "$OPENSSL_SHA" "openssl-$OPENSSL_VERSION.tar.gz"
  rm -rf openssl-src
  mkdir openssl-src
  tar xzf "openssl-$OPENSSL_VERSION.tar.gz" -C openssl-src --strip-components=1
}

# Fresh, patched openconnect-src/ from the pinned tarball.
unpack_openconnect() {
  fetch "https://www.infradead.org/openconnect/download/openconnect-$OPENCONNECT_VERSION.tar.gz" \
    "$OPENCONNECT_SHA" "openconnect-$OPENCONNECT_VERSION.tar.gz"
  rm -rf openconnect-src
  mkdir openconnect-src
  tar xzf "openconnect-$OPENCONNECT_VERSION.tar.gz" -C openconnect-src --strip-components=1
  # OpenSSL 3 refuses gateways without secure renegotiation (e.g. vpn.bri.co.id);
  # the patch allows them, as GnuTLS builds do, without --allow-insecure-crypto.
  patch -s -d openconnect-src -p1 < "$SCRIPT_DIR/patches/openconnect-legacy-renegotiation.patch"
}

# Fresh libxml2-src/ from the pinned tarball.
unpack_libxml2() {
  fetch "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/libxml2-$LIBXML2_VERSION.tar.xz" \
    "$LIBXML2_SHA" "libxml2-$LIBXML2_VERSION.tar.xz"
  rm -rf libxml2-src
  mkdir libxml2-src
  tar xJf "libxml2-$LIBXML2_VERSION.tar.xz" -C libxml2-src --strip-components=1
}
