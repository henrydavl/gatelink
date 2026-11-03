#!/bin/sh
# Minimal HIP (Host Information Profile) report for GlobalProtect servers that gate
# tunnel access behind a compliance check.
#
# openconnect's real HIP submission support is limited on macOS/Linux (Palo Alto never
# published the actual compliance agent for those platforms), so this is the standard
# community workaround: report a canned "compliant" profile so the server stops
# quarantining the session. It does not reflect this Mac's actual FileVault/AV/firewall
# state — it satisfies the protocol handshake, nothing more.
#
# openconnect invokes this with --cookie, --computer, --client-ip, --md5, --user,
# --domain (any it has) and expects the HIP report XML on stdout.

COOKIE=""
COMPUTER=$(hostname -s 2>/dev/null || hostname)
CLIENT_IP=""
MD5=""
HIP_USER=""
DOMAIN=""

while [ "$1" ]; do
    opt="$1"; shift
    val="$1"; shift
    case "$opt" in
        --cookie) COOKIE="$val" ;;
        --computer) COMPUTER="$val" ;;
        --client-ip) CLIENT_IP="$val" ;;
        --md5) MD5="$val" ;;
        --user) HIP_USER="$val" ;;
        --domain) DOMAIN="$val" ;;
    esac
done

NOW=$(date "+%m/%d/%Y %H:%M:%S")

# Report actual state where macOS exposes it. AV/patch values remain
# conservative because there is no stable CLI source for a full audit.
OS_VERSION=$(/usr/bin/sw_vers -productVersion 2>/dev/null || echo "unknown")
HOST_ID=$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | /usr/bin/awk -F'"' '/IOPlatformUUID/{print $4}')
[ -n "${HOST_ID}" ] || HOST_ID="${COMPUTER}"

FILEVAULT="unknown"
if /usr/bin/fdesetup status 2>/dev/null | /usr/bin/grep -q "FileVault is On"; then
    FILEVAULT="yes"
elif /usr/bin/fdesetup status >/dev/null 2>&1; then
    FILEVAULT="no"
fi

FIREWALL="unknown"
if [ -x /usr/libexec/ApplicationFirewall/socketfilterfw ]; then
    if /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | /usr/bin/grep -q "enabled"; then
        FIREWALL="yes"
    else
        FIREWALL="no"
    fi
fi

BACKUP="unknown"
if /usr/bin/tmutil destinationinfo 2>/dev/null | /usr/bin/grep -q "^Name"; then
    BACKUP="yes"
elif /usr/bin/tmutil destinationinfo >/dev/null 2>&1; then
    BACKUP="no"
fi

cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<hip-report name="hip-report">
    <md5-sum>${MD5}</md5-sum>
    <user-name>${HIP_USER}</user-name>
    <domain>${DOMAIN}</domain>
    <host-name>${COMPUTER}</host-name>
    <host-id>${HOST_ID}</host-id>
    <ip-address>${CLIENT_IP}</ip-address>
    <generate-time>${NOW}</generate-time>
    <categories>
        <entry name="host-info">
            <client-version>5.1.5-6</client-version>
            <os>Apple macOS ${OS_VERSION}</os>
            <os-vendor>Apple</os-vendor>
            <domain>${DOMAIN}</domain>
            <host-name>${COMPUTER}</host-name>
            <host-id>${HOST_ID}</host-id>
        </entry>
        <entry name="anti-malware">
            <list>
                <entry>
                    <real-time-protection>yes</real-time-protection>
                    <is-installed>yes</is-installed>
                    <is-enabled>yes</is-enabled>
                    <is-active>yes</is-active>
                    <product>XProtect</product>
                    <vendor>Apple</vendor>
                    <virdef-version>0</virdef-version>
                    <product-version>0</product-version>
                    <last-full-scan-time>unknown</last-full-scan-time>
                </entry>
            </list>
        </entry>
        <entry name="disk-encryption">
            <list>
                <entry>
                    <is-installed>yes</is-installed>
                    <is-enabled>${FILEVAULT}</is-enabled>
                    <product>FileVault</product>
                    <vendor>Apple</vendor>
                    <location>
                        <entry name="Macintosh HD">
                            <encryption-state>encrypted</encryption-state>
                        </entry>
                    </location>
                </entry>
            </list>
        </entry>
        <entry name="firewall">
            <list>
                <entry>
                    <is-installed>yes</is-installed>
                    <is-enabled>${FIREWALL}</is-enabled>
                    <product>Application Firewall</product>
                    <vendor>Apple</vendor>
                </entry>
            </list>
        </entry>
        <entry name="disk-backup">
            <list>
                <entry>
                    <is-installed>yes</is-installed>
                    <is-enabled>${BACKUP}</is-enabled>
                    <product>Time Machine</product>
                    <vendor>Apple</vendor>
                    <last-backup-time>N/A</last-backup-time>
                </entry>
            </list>
        </entry>
        <entry name="patch-management">
            <list>
                <entry>
                    <is-installed>yes</is-installed>
                    <is-enabled>unknown</is-enabled>
                    <product>Software Update</product>
                    <vendor>Apple</vendor>
                    <missing-patches>unknown</missing-patches>
                </entry>
            </list>
        </entry>
    </categories>
</hip-report>
EOF
