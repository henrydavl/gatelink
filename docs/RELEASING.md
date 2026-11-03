# Releasing GateLink

## Release assets

Each release ships two installers, both requiring macOS 14:

| Asset | Architecture |
|-------|--------------|
| `GateLink-arm64.pkg` | Apple Silicon: app + tunnel helper |
| `GateLink-x64.pkg` | Intel: app + tunnel helper |

The `.pkg`'s `postinstall` (`scripts/pkg/postinstall`) runs the bundled
`install-tunnel-helper.sh` for the logged-in user. It is unsigned, so users
allow it once under Privacy & Security.

Releases no longer ship DMGs, zips or update signatures. The Swift app has no
updater, and the v0.1.x .NET updater only installed signed DMGs, so v0.1.x
users upgrade by installing the `.pkg` by hand.

## Release flow

1. Push a tag `vX.Y.Z` (v2 and later are the Swift app).
2. The `test` job runs `swift test --package-path GateLinkKit`, checks the
   shell scripts and runs the tunnel wrapper test.
3. CI builds both macOS apps in a matrix:
   - `macos-15` → arm64
   - `macos-15-intel` → x64
   Each job builds the OpenConnect engine from pinned sources with
   `-mmacosx-version-min=14.0` (see below), bundles it into the `.app`, builds
   the app with XcodeGen + `xcodebuild` (`scripts/build-macos-app.sh`), then
   the `.pkg` (`scripts/build-macos-pkg.sh`).
4. The release job publishes both `.pkg` files with generated release notes.

## macOS runner compatibility and the bundled engine

GitHub no longer offers macOS 14 runners (retired November 2, 2026), and a
Homebrew bottle poured on macOS 15/26 carries that OS as its `minos`. Copying
a Homebrew openconnect would therefore raise GateLink's real minimum above the
`LSMinimumSystemVersion` in `Info.plist`, producing `dyld: Symbol not found`
on macOS 14.

`scripts/build-openconnect-engine.sh` builds OpenSSL and OpenConnect from
pinned sources with `-mmacosx-version-min=14.0`, using OpenSSL instead of
GnuTLS so Homebrew's p11-kit/GnuTLS stack is not linked in. libxml2 comes from
the SDK. CI verifies every bundled Mach-O has `minos <= 14.0`.

The workflow uses `macos-15` (arm64) and `macos-15-intel` (x64) and selects
Xcode 26.3 on both. The SDK, not the runner OS, decides the app's look: macOS
26 draws an app built with the macOS 15 SDK in the old style, so CI fails if
the app's SDK is below 26. The runner
version no longer determines the engine's deployment target, so moving to
newer runners only changes the build toolchain; keep the `MAX=14.0` check.

macOS 12–13 still needs a separate build: lower `LSMinimumSystemVersion`, set
`TARGET` in `scripts/build-openconnect-engine.sh` (and `-target` in
`project.yml`), and use an SDK that supports that target.

## Notarization

The current app is **ad-hoc signed**, not Developer ID signed or notarized.
Gatekeeper rejects it on first launch unless the user explicitly allows it. For
public distribution, sign with a Developer ID Application certificate and
notarize with `notarytool` (for a `.pkg`, sign it with a Developer ID
Installer certificate).


## Upgrading from the .NET app (v0.1.x)

- The Swift app keeps the bundle ID `com.gatelink.app`. It needs tunnel
  helper v6 (v4 came with the .NET app), so the `.pkg`, or else the first
  Connect, upgrades the helper and replaces any old NOPASSWD sudoers rule.
  Bump `HELPER_VERSION` in `scripts/install-tunnel-helper.sh` and
  `TunnelHelper.expectedVersion` together.
- The Swift app does not read the old vault (`vault.enc`). Users add their 2FA
  account again and enter the VPN password once.
- The old Open at Login LaunchAgent is removed on first launch; the setting
  now uses `SMAppService`.
- Delete `~/gatelink-auth.log` from very old builds; it may contain a session
  cookie.
