#!/usr/bin/env bash
#
# bundle-openconnect.sh — collect openconnect + its dylibs into the app bundle
# so GateLink ships a working VPN engine and users don't need `brew install`.
#
# It copies the openconnect binary, every non-system dylib it needs
# (recursively), and vpnc-script into a staging folder, then rewrites all the
# Mach-O load paths to be relative (@loader_path), making the set relocatable.
#
# Output: Engine/openconnect/  (embedded into GateLink.app/Contents/Helpers by Xcode)
#
# Inputs:
#   GATELINK_OPENCONNECT    openconnect binary to bundle (default: PATH/Homebrew)
#   GATELINK_EXTRA_PREFIX   additional prefix whose dylibs should be copied and
#                           rewritten to @loader_path (used by CI's source build)
#   GATELINK_VPNC_SCRIPT    vpnc-script to bundle (default: Homebrew/system)
#
# Run this on a Mac that already has a working openconnect (e.g. via Homebrew),
# or after scripts/build-openconnect-engine.sh.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Engine/openconnect"
OC="${GATELINK_OPENCONNECT:-$(command -v openconnect || echo /opt/homebrew/bin/openconnect)}"
EXTRA_PREFIX="${GATELINK_EXTRA_PREFIX:-}"

if [ ! -x "$OC" ]; then
  echo "ERROR: openconnect not found. Install it first (brew install openconnect)." >&2
  exit 1
fi

echo "Bundling from: $OC"
rm -rf "$OUT"
mkdir -p "$OUT"

# 1. Gather the binary + all non-system dylibs it needs (recursively).
python3 - "$OC" "$OUT" "$EXTRA_PREFIX" <<'PY'
import subprocess, sys, os, shutil
oc, out, extra = sys.argv[1], sys.argv[2], sys.argv[3]
prefixes = [p for p in ("/opt/homebrew", "/usr/local", extra) if p]

def bundled(path):
    return any(path == p or path.startswith(p + "/") for p in prefixes)

def deps(f):
    try:
        lines = subprocess.check_output(["otool","-L",f], text=True).splitlines()[1:]
    except Exception:
        return []
    r = []
    for ln in lines:
        p = ln.strip().split(" ")[0]
        if bundled(p):
            r.append(p)
    return r

# Map each referenced path to the name it is referenced BY (not realpath), so
# the copied file name matches what the Mach-O loader looks for.
seen=set(); queue=[oc]; refs={}   # refs[basename-as-referenced] = real file to copy
while queue:
    f = queue.pop()
    key = os.path.basename(f)
    if key in seen: continue
    seen.add(key)
    real = os.path.realpath(f)
    if f != oc:
        refs[key] = real
    for d in deps(real):
        queue.append(d)

# Copy the binary as "openconnect"
shutil.copy2(os.path.realpath(oc), os.path.join(out, "openconnect"))
os.chmod(os.path.join(out, "openconnect"), 0o755)

# Copy each dylib under the exact name it is referenced by.
for name, real in refs.items():
    shutil.copy2(real, os.path.join(out, name))

print("copied", len(refs), "dylibs +", "openconnect")
PY

# 2. Rewrite load paths to @loader_path so the set is relocatable.
is_bundled_dep() {
  local dep="$1"
  [[ "$dep" == /opt/homebrew/* || "$dep" == /usr/local/* ]] && return 0
  [[ -n "$EXTRA_PREFIX" && "$dep" == "$EXTRA_PREFIX"/* ]] && return 0
  return 1
}

echo "Rewriting dylib paths..."
cd "$OUT"
for f in openconnect *.dylib; do
  [ -f "$f" ] || continue
  # For each non-system dependency, repoint it to @loader_path/<basename>.
  otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    if is_bundled_dep "$dep"; then
      base="$(basename "$dep")"
      install_name_tool -change "$dep" "@loader_path/$base" "$f" 2>/dev/null || true
    fi
  done
  # Fix the library's own id too.
  if [[ "$f" == *.dylib ]]; then
    install_name_tool -id "@loader_path/$f" "$f" 2>/dev/null || true
  fi
  # Re-sign ad-hoc after modification (required on Apple Silicon).
  codesign --force --sign - "$f" 2>/dev/null || true
done

# 3. Bundle vpnc-script (needed to configure routes on connect).
# Use deterministic locations first; `find | head` can trip pipefail.
VPNC=""
if [ -n "${GATELINK_VPNC_SCRIPT:-}" ] && [ -f "$GATELINK_VPNC_SCRIPT" ]; then
  VPNC="$GATELINK_VPNC_SCRIPT"
else
  for candidate in \
    /opt/homebrew/etc/vpnc/vpnc-script \
    /usr/local/etc/vpnc/vpnc-script \
    /etc/vpnc/vpnc-script; do
    if [ -f "$candidate" ]; then VPNC="$candidate"; break; fi
  done
fi
if [ -z "$VPNC" ]; then
  VPNC="$(find /opt/homebrew /usr/local -name vpnc-script -print -quit 2>/dev/null || true)"
fi
if [ -n "$VPNC" ]; then
  cp "$VPNC" "$OUT/vpnc-script"
  chmod +x "$OUT/vpnc-script"
  echo "bundled vpnc-script"
else
  echo "WARNING: vpnc-script not found; the tunnel will not configure routes." >&2
fi

echo
echo "Done. Bundled openconnect into: $OUT"
ls -la "$OUT"
