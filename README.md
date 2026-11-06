# GateLink

A macOS menu bar helper that logs you in to the official **GlobalProtect** app
with one click, for gateways that use a password plus a TOTP code. GateLink keeps
the 2FA secret and VPN password in the Keychain behind Touch ID, generates the
6-digit code itself, and fills in GlobalProtect's login window for you.

GateLink does not make a VPN connection. GlobalProtect does, as if you had typed
the login yourself, and sends its own device (HIP) report.

Written in Swift and SwiftUI. Requires macOS 14 Sonoma or later, on Apple Silicon
or Intel, with GlobalProtect installed and running.

## How a login works

```
Connect
  ├─ check Accessibility permission, and that the running GlobalProtect is
  │    signed by Palo Alto Networks (team PXPZ95SK77)
  ├─ Touch ID unlocks the vault, every time
  ├─ if the code expires within 8 s, or was already used, wait for the next one
  ├─ press GlobalProtect's menu bar icon, then Connect on the portal screen
  ├─ fill Username and Password (<password><6-digit code>), press Connect once
  └─ wait for GlobalProtect to report the connection
```

GateLink tries **once** per Connect, because repeated bad logins can lock the
account. It also follows `pan_gp_event.log`, so a login by hand shows as connected.
When the session ends you get a notification; clicking it starts a new login.

GateLink recognises GlobalProtect 6.0's English labels. If an update changes them,
Connect fails with a message and you can log in to GlobalProtect by hand.

## Layout

| Path | What it is |
|------|------------|
| `GateLink/` | The SwiftUI app: menu bar popover, Add Account and password windows |
| `GateLinkKit/` | Swift package with all logic, unit-tested with `swift test` |
| `GateLinkKit/Sources/GateLinkKit/GlobalProtect` | The login flow and the Accessibility calls into GlobalProtect |
| `GateLinkKit/Sources/GateLinkKit/OTP` | Base32, RFC 6238 TOTP, `otpauth://` parsing, QR reading (Vision) |
| `GateLinkKit/Sources/GateLinkKit/Vault` | Accounts, Keychain secret store, Touch ID gate |
| `GateLinkKit/Sources/GateLinkKit/Update` | Release check, checksum-verified `.pkg` download, install and relaunch |
| `scripts/pkg` | Installer scripts; `postinstall` removes the old tunnel helper |
| `project.yml` | XcodeGen spec for `GateLink.xcodeproj` |

## Build

Requirements: Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
./scripts/build-macos-app.sh      # → dist/GateLink.app
./scripts/build-macos-pkg.sh      # → dist/GateLink.pkg
swift test --package-path GateLinkKit
```

To work in Xcode, run `xcodegen generate` and open `GateLink.xcodeproj`. The tests
need no VPN: the login flow runs against a fake GlobalProtect.

## Security model

- **Secrets** (TOTP seed, VPN password) are stored per account in the login
  Keychain. The item's access list trusts only GateLink, and the app asks for
  Touch ID (or the login password) before reading one. Account names and settings
  are plain JSON in `~/Library/Application Support/GateLink`.
- **Both login factors live on this Mac.** Keeping the 2FA secret beside the
  password is the convenience this app exists for, and a security review may
  count it as one factor. Check your organisation's policy before using it.
- **Accessibility permission** lets GateLink control other apps. It only presses
  GlobalProtect's controls and only reads its labels, never a field's contents.
- **The password** goes only to a process with GlobalProtect's bundle ID and Palo
  Alto Networks' signature, checked again right before filling. GateLink clears
  the field if the login fails.

## Upgrading

- **From 2.x:** installing the `.pkg` stops any GateLink tunnel and removes the
  root helper (`/usr/local/libexec/gatelink`) and its sudo rule
  (`/etc/sudoers.d/gatelink`). Deleting the app alone leaves them behind. Your
  accounts and passwords carry over.
- **From the .NET version (v0.1.x):** the app does not read the old vault, so add
  your 2FA account again and enter the VPN password once. The old
  `~/gatelink-auth.log` may contain a session cookie; delete it. v0.1.x does not
  update itself: install the `.pkg` from the release.

## Troubleshooting

**"Allow GateLink in System Settings"**: turn it on under Privacy & Security >
Accessibility. Builds are ad-hoc signed, so macOS may need this again after an
update: remove GateLink from the list and add it again.

**"GlobalProtect didn't accept the login"**: check the password saved in GateLink,
and that the Mac's clock is right (codes are time-based). GateLink won't retry.

**"GlobalProtect didn't show its login screen"**: check its window for a network
or portal error, or log in there by hand.
