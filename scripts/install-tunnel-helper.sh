#!/bin/bash
#
# install-tunnel-helper.sh — install the root-owned GateLink tunnel helper.
#
# Unlike the old install-sudoers.sh, this does NOT grant NOPASSWD to
# openconnect, kill, or any user-writable file. It installs a fixed-purpose
# wrapper and root-owned copies of openconnect, vpnc-script, and hipreport.sh:
#
#   /usr/local/libexec/gatelink/gatelink-tunnel   (root:wheel 0755)
#   /usr/local/libexec/gatelink/openconnect       (root:wheel 0755)
#   /usr/local/libexec/gatelink/*.dylib           (root:wheel 0644)
#   /usr/local/libexec/gatelink/vpnc-script       (root:wheel 0755)
#   /usr/local/libexec/gatelink/hipreport.sh      (root:wheel 0755)
#   /etc/sudoers.d/gatelink                        (root:wheel 0440)
#
# The sudoers rule authorizes exactly one command: the wrapper. The wrapper
# validates its arguments and builds the openconnect argv itself.
#
# USAGE
#   sudo ./install-tunnel-helper.sh --user "$USER"
#   sudo ./install-tunnel-helper.sh --uninstall
#
set -euo pipefail

HELPER_DIR="/usr/local/libexec/gatelink"
SUDOERS_FILE="/etc/sudoers.d/gatelink"
HELPER_VERSION="5"

TARGET_USER="${SUDO_USER:-$(stat -f '%Su' /dev/console 2>/dev/null || true)}"
UNINSTALL=0
CHECK_ONLY=0

die() {
    echo "install-tunnel-helper: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
usage: install-tunnel-helper.sh [--user USER] [--uninstall] [--check]

  --user USER       user allowed to run the helper (default: SUDO_USER/console user)
  --uninstall       remove the helper and its sudoers rule
  --check           print resolved sources and exit without installing
EOF
    exit 2
}

while (( $# )); do
    case "${1}" in
        --user)
            [[ $# -ge 2 ]] || usage
            TARGET_USER="${2}"
            shift 2
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        --check)
            CHECK_ONLY=1
            shift
            ;;
        *)
            usage
            ;;
    esac
done

if (( UNINSTALL )); then
    if [[ "${EUID}" -ne 0 ]]; then
        exec /usr/bin/sudo "$0" --uninstall
    fi
    echo "Removing ${SUDOERS_FILE} and ${HELPER_DIR} ..."
    /bin/rm -f "${SUDOERS_FILE}"
    /bin/rm -rf "${HELPER_DIR}"
    echo "Done. GateLink can no longer create a tunnel until the helper is reinstalled."
    exit 0
fi

[[ -n "${TARGET_USER}" ]] || die "cannot determine target user; pass --user"
[[ "${TARGET_USER}" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid user name: ${TARGET_USER}"
/usr/bin/id -u "${TARGET_USER}" >/dev/null 2>&1 || die "user does not exist: ${TARGET_USER}"

# --- locate sources -----------------------------------------------------------
# Works both from the app bundle (Contents/Resources) and from the repo.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "${SCRIPT_DIR}" == */Contents/Resources ]]; then
    APP="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    ENGINE="${APP}/Contents/Helpers/openconnect"
    VPNC_SRC="${SCRIPT_DIR}/vpnc-script"
    WRAPPER="${SCRIPT_DIR}/gatelink-tunnel"
    HIP_SRC="${SCRIPT_DIR}/hipreport.sh"
else
    ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    WRAPPER="${ROOT}/scripts/gatelink-tunnel"
    HIP_SRC="${ROOT}/scripts/hipreport.sh"
    if [[ -d "${ROOT}/dist/GateLink.app/Contents/Helpers/openconnect" ]]; then
        APP="${ROOT}/dist/GateLink.app"
        ENGINE="${APP}/Contents/Helpers/openconnect"
        VPNC_SRC="${APP}/Contents/Resources/vpnc-script"
    else
        APP=""
        ENGINE="${ROOT}/Engine/openconnect"
        VPNC_SRC="${ENGINE}/vpnc-script"
    fi
fi

OC_SRC="${ENGINE}/openconnect"

# Older/local app bundles may not include vpnc-script. Fall back to the
# Homebrew/System copy and install a root-owned copy of it.
if [[ ! -f "${VPNC_SRC}" ]]; then
    for candidate in \
        /opt/homebrew/etc/vpnc/vpnc-script \
        /usr/local/etc/vpnc/vpnc-script \
        /etc/vpnc/vpnc-script; do
        if [[ -f "${candidate}" ]]; then VPNC_SRC="${candidate}"; break; fi
    done
fi

[[ -f "${WRAPPER}" ]] || die "wrapper not found: ${WRAPPER}"
[[ -x "${OC_SRC}" ]] || die "bundled openconnect not found: ${OC_SRC} (run scripts/bundle-openconnect.sh)"
[[ -f "${VPNC_SRC}" ]] || die "vpnc-script not found (run scripts/bundle-openconnect.sh)"
[[ -f "${HIP_SRC}" ]] || die "hipreport.sh not found: ${HIP_SRC}"

echo "User:        ${TARGET_USER}"
echo "App:         ${APP:-<repo/dev assets>}"
echo "Helper dir:  ${HELPER_DIR}"
echo "Sudoers:     ${SUDOERS_FILE}"
echo "Sources:"
echo "  openconnect  ${OC_SRC}"
echo "  vpnc-script  ${VPNC_SRC}"
echo "  hipreport    ${HIP_SRC}"
echo "  wrapper      ${WRAPPER}"

if (( CHECK_ONLY )); then
    echo "Check only: not installing."
    exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
    exec /usr/bin/sudo "$0" --user "${TARGET_USER}"
fi

# --- build the rule in a temp file and validate it ----------------------------
TMP_RULE="$(/usr/bin/mktemp /tmp/gatelink-sudoers.XXXXXX)"
trap '/bin/rm -f "${TMP_RULE}"' EXIT

{
    echo "# Installed by GateLink install-tunnel-helper.sh"
    echo "# Only the fixed-purpose wrapper is authorized; it validates its own args."
    echo "${TARGET_USER} ALL=(root) NOPASSWD: ${HELPER_DIR}/gatelink-tunnel"
} > "${TMP_RULE}"


echo "Validating sudoers rule ..."
/usr/sbin/visudo -cf "${TMP_RULE}"

echo "Installing helper files ..."
/usr/bin/install -d -m 0755 -o root -g wheel "${HELPER_DIR}"
/usr/bin/install -m 0755 -o root -g wheel "${WRAPPER}" "${HELPER_DIR}/gatelink-tunnel"
/usr/bin/install -m 0755 -o root -g wheel "${OC_SRC}" "${HELPER_DIR}/openconnect"
/usr/bin/install -m 0755 -o root -g wheel "${VPNC_SRC}" "${HELPER_DIR}/vpnc-script"
/usr/bin/install -m 0755 -o root -g wheel "${HIP_SRC}" "${HELPER_DIR}/hipreport.sh"
/bin/rm -f "${HELPER_DIR}/allowed-gateways"
printf '%s\n' "${HELPER_VERSION}" > "${HELPER_DIR}/VERSION"
/usr/sbin/chown root:wheel "${HELPER_DIR}/VERSION"
/bin/chmod 0644 "${HELPER_DIR}/VERSION"

for dylib in "${ENGINE}"/*.dylib; do
    [[ -f "${dylib}" ]] || continue
    /usr/bin/install -m 0644 -o root -g wheel "${dylib}" "${HELPER_DIR}/$(basename "${dylib}")"
done

# Re-sign the copied root-owned binaries ad-hoc so macOS will execute them.
/usr/bin/codesign --force --sign - "${HELPER_DIR}/openconnect" >/dev/null 2>&1 || true
for dylib in "${HELPER_DIR}"/*.dylib; do
    [[ -f "${dylib}" ]] || continue
    /usr/bin/codesign --force --sign - "${dylib}" >/dev/null 2>&1 || true
done

# Remove the obsolete marker used by the old .NET NOPASSWD implementation.
TARGET_HOME="$(/usr/bin/dscl . -read "/Users/${TARGET_USER}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
if [[ -n "${TARGET_HOME}" ]]; then
    /bin/rm -f "${TARGET_HOME}/Library/Application Support/GateLink/sudoers-authorized-path.txt"
fi

echo "Installing sudoers rule ..."
/usr/bin/install -m 0440 -o root -g wheel "${TMP_RULE}" "${SUDOERS_FILE}"
/usr/sbin/visudo -c >/dev/null

echo
echo "Installed. ${TARGET_USER} may run only:"
echo "  sudo -n ${HELPER_DIR}/gatelink-tunnel ..."
echo "To remove: sudo $0 --uninstall"
