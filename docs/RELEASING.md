# Releasing GateLink

## Release assets

Each release ships two Mac installers, both requiring macOS 14:

| Asset | For |
|-------|-----|
| `GateLink-arm64.pkg` | Apple Silicon |
| `GateLink-x64.pkg` | Intel |

The `.pkg`'s `postinstall` (`scripts/pkg/postinstall`) removes the tunnel helper
that versions before 3.0 installed. Keep it while anyone may upgrade from 2.x. The
package is unsigned, so users allow it once under Privacy & Security.

The Mac app's updater looks only for `GateLink-<arch>.pkg`. The v0.1.x .NET updater
only installed signed DMGs, so v0.1.x users install the `.pkg` by hand.

## Release flow

1. Push a tag `vX.Y.Z`.
2. The `test` job runs `swift test --package-path GateLinkKit` and checks the
   shell scripts.
3. CI builds both macOS apps in a matrix (`macos-15` → arm64, `macos-15-intel` →
   x64) with XcodeGen + `xcodebuild` (`scripts/build-macos-app.sh`), then the
   `.pkg` (`scripts/build-macos-pkg.sh`).
4. The release job publishes both `.pkg` files with generated release notes.

The workflow selects Xcode 26.3 on both runners. The SDK, not the runner OS, decides
the app's look: macOS 26 draws an app built with the macOS 15 SDK in the old style,
so CI fails if the app's SDK is below 26.

## Notarization

The app is **ad-hoc signed**, not Developer ID signed or notarized. Gatekeeper
rejects it on first launch unless the user explicitly allows it, and macOS ties the
Accessibility permission to the signature, so users may have to grant it again after
each update. Signing with a Developer ID Application certificate fixes both; for a
`.pkg`, also sign it with a Developer ID Installer certificate and notarize with
`notarytool`.

## Upgrading from the .NET app (v0.1.x)

- The Swift app keeps the bundle ID `com.gatelink.app`, and does not read the old
  vault (`vault.enc`). Users add their 2FA account again and enter the VPN password
  once.
- The old Open at Login LaunchAgent is removed on first launch; the setting now
  uses `SMAppService`.
- Delete `~/gatelink-auth.log` from very old builds; it may contain a session cookie.
