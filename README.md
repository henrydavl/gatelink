# GateLink

A native macOS menu bar client for **GlobalProtect** VPN gateways that use a
password plus a TOTP code. GateLink keeps the 2FA secret and VPN password in
the Keychain behind Touch ID, generates the 6-digit code itself, and connects
in one click. The VPN protocol is handled by the open-source
[OpenConnect](https://www.infradead.org/openconnect/) engine bundled in the app.

Written in Swift and SwiftUI. Requires macOS 14 Sonoma or later, on Apple
Silicon or Intel. An iPhone version with the same screens is sideloaded from
Xcode; see [iOS](#ios).

## How a connection works

```
Connect
  ├─ Touch ID unlocks the vault (one unlock lasts 60 s of activity)
  ├─ openconnect --protocol=gp --usergroup=gateway -u <user> --authenticate <portal>
  │     run in a pseudo-terminal; the single prompt gets <password><6-digit OTP>
  │     → session cookie + server certificate pin
  └─ sudo -n /usr/local/libexec/gatelink/gatelink-tunnel connect --host <h> --fingerprint <pin>
        root-owned wrapper starts openconnect with fixed options; cookie on stdin
        → "Connected" once openconnect reports the tunnel is up (≤ 30 s)
```

If the tunnel drops while connected, GateLink logs in again with a fresh code
(three attempts: after 2, 5 and 10 seconds). The VPN lives only as long
as the app: quitting, a crash or Force Quit takes the tunnel down.

## Layout

| Path | What it is |
|------|------------|
| `GateLink/` | The SwiftUI app: menu bar popover, Add Account and Requirements windows |
| `GateLink/App/AppModel.swift`, `GateLink/Shared` | App state and views shared with the iOS app |
| `GateLinkiOS/` | The iOS app; `Shared/GLOpenConnect.c` is the C layer over libopenconnect |
| `GateLinkTunnel/` | The iOS Packet Tunnel extension that runs the tunnel |
| `GateLinkKit/` | Swift package with all logic, unit-tested with `swift test` |
| `GateLinkKit/Sources/GateLinkKit/OTP` | Base32, RFC 6238 TOTP, `otpauth://` parsing, QR reading (Vision) |
| `GateLinkKit/Sources/GateLinkKit/Vault` | Accounts, Keychain secret store, Touch ID gate with sliding relock |
| `GateLinkKit/Sources/GateLinkKit/Update` | Release check, checksum-verified `.pkg` download, install and relaunch |
| `GateLinkKit/Sources/GateLinkKit/VPN` | PTY login, cookie parsing, tunnel controller, helper installer, `VPNSession` state machine |
| `scripts/gatelink-tunnel` | Root-owned wrapper; the only command sudoers allows |
| `scripts/install-tunnel-helper.sh` | Installs the wrapper, engine and sudoers rule |
| `scripts/build-openconnect-engine.sh` | Builds OpenConnect + OpenSSL from pinned sources for macOS 14 |
| `scripts/build-openconnect-ios.sh` | Builds static libopenconnect + OpenSSL for iOS into `Engine/ios` |
| `scripts/engine-sources.sh` | The pinned source versions and checksums both engine builds use |
| `scripts/bundle-openconnect.sh` | Stages the engine and its dylibs in `Engine/openconnect` |
| `project.yml` | XcodeGen spec for `GateLink.xcodeproj` |

## Build

Requirements: Xcode 16 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and an OpenConnect engine to bundle.

```bash
# Engine: either reuse a local Homebrew openconnect (fine for your own Mac)…
brew install openconnect
./scripts/bundle-openconnect.sh

# …or build the distributable macOS 14 engine from source (what CI does).
./scripts/build-openconnect-engine.sh
PREFIX="${TMPDIR%/}/gatelink-engine"
GATELINK_OPENCONNECT="$PREFIX/sbin/openconnect" GATELINK_EXTRA_PREFIX="$PREFIX" \
  GATELINK_VPNC_SCRIPT="$PREFIX/etc/vpnc/vpnc-script" ./scripts/bundle-openconnect.sh

./scripts/build-macos-app.sh      # → dist/GateLink.app
./scripts/build-macos-pkg.sh      # → dist/GateLink.pkg (app + tunnel helper in one install)
```

To work in Xcode, run `xcodegen generate` and open `GateLink.xcodeproj`.

Run the tests:

```bash
swift test --package-path GateLinkKit
```

The tests need no network or VPN: the login is exercised against a fake
`openconnect` script, and the session state machine against fake tunnels.

## iOS

The iPhone app has the popover's screens: the account and code (tap to copy),
Portal, Username, a password sheet with AutoFill, and Connect. iOS cannot run
`openconnect` or `sudo`, so the parts are split differently:

```
Connect
├─ Face ID unlocks the vault
├─ the app logs in with libopenconnect: password + OTP → cookie + certificate pin
│     (the certificate must be trusted by iOS for the portal name you typed)
└─ startVPNTunnel → GateLinkTunnel (Packet Tunnel extension)
      libopenconnect opens the SSL tunnel with the cookie, accepting only the pin;
      iOS applies the gateway's address, split routes and DNS
```

The VPN keeps running after GateLink closes; reopening it picks the tunnel up.
A failed tunnel logs in again with a fresh code while the app is open; turning
the VPN off in Settings does not reconnect. The HIP report the macOS app sends
(`hipreport.sh`) is not sent on iOS.

Apple allows Network Extensions only for paid developer teams, so a free
Personal Team cannot sign it. The targets use `com.example.gatelink` IDs. Put
your team in `GateLinkiOS/Signing.local.xcconfig` (gitignored, so it stays out
of the repo), sign in to that account in Xcode, then:

```bash
echo 'DEVELOPMENT_TEAM = ABCDE12345' > GateLinkiOS/Signing.local.xcconfig
./scripts/build-openconnect-ios.sh   # → Engine/ios (static, iOS 18.4+)
xcodegen generate
xcodebuild -project GateLink.xcodeproj -scheme GateLinkiOS -derivedDataPath build/ios \
  -destination 'id=<iPhone UDID>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <iPhone UDID> \
  build/ios/Build/Products/Debug-iphoneos/GateLink.app
```

Or open `GateLink.xcodeproj` and run the `GateLinkiOS` scheme on the phone.
Tunnel logs are in Console.app under the subsystem `com.example.gatelink`.

## Security model

- **Secrets** (TOTP seed, VPN password) are stored per account in the login
  Keychain. The item's access list trusts only GateLink, and the app asks for
  Touch ID (or the login password) before reading one. Account names and
  settings are plain JSON in `~/Library/Application Support/GateLink`.
- **The credential** is written to openconnect's terminal with echo disabled,
  never passed on a command line, and redacted from any error text.
- **Root access** goes through one fixed-purpose wrapper. sudoers authorizes
  only `/usr/local/libexec/gatelink/gatelink-tunnel`; it accepts a validated
  host and certificate pin, builds the openconnect command itself from
  root-owned files, and only signals a PID that is its own openconnect.
  The app checks the host and pin too before calling it.
- **Approved portals**: the wrapper connects only to portals listed in the
  root-owned `/usr/local/libexec/gatelink/allowed-gateways`. A new portal is
  added with one administrator prompt on its first Connect, so another program
  running as you cannot point the root tunnel at its own server.
- **Logs**: tunnel output goes to `~/Library/Logs/GateLink/tunnel.log` (0600,
  rotated at 512 KB). The session cookie travels on stdin and is never logged.

Remove the helper from the Requirements window, or with
`./scripts/install-tunnel-helper.sh --uninstall`.

## Upgrading from the .NET version (v0.1.x)

The Swift app does not read the old vault. After upgrading, add your 2FA
account again (QR image or secret key) and enter the VPN password once. The old
`~/gatelink-auth.log` may contain a session cookie; delete it. v0.1.x does
not update itself to v2: install the `.pkg` from the release.

## Troubleshooting

**"Root tunnel helper missing or not authorized"**: press Connect and approve
the administrator prompt, or run `./scripts/install-tunnel-helper.sh --user "$USER"`.

**"Login failed"**: check the username, the password, and that the Mac's
clock is right (codes are time-based).

**Anything else**: open … → Requirements… in the popover, and check
`~/Library/Logs/GateLink/tunnel.log`.
