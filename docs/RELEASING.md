# Releasing GateLink

## Signing key

The .NET builds (v0.1.x) auto-update by verifying a detached RSA-SHA256
signature over the DMG with a pinned public key. The Swift app (v2) has no
updater yet, but CI keeps signing releases with the same key so v0.1.x
installs can update to v2 in place.

The private key was generated into `.secrets/gatelink-release.key` (gitignored).
**Never commit it.** Store it in a password manager and add its base64 form as a
GitHub Actions secret named `GATELINK_RELEASE_KEY`:

```bash
base64 -i .secrets/gatelink-release.key | pbcopy
```

If the secret is absent, CI still publishes the DMG but **does not sign it**;
v0.1.x apps then refuse to auto-install it and open the download page instead.

## Architecture-specific assets

macOS releases ship two apps, both requiring macOS 14:

| Asset | Architecture |
|-------|--------------|
| `GateLink-arm64.dmg` | Apple Silicon |
| `GateLink-x64.dmg` | Intel |

`GateLink.dmg` is a byte-identical copy of the arm64 DMG kept so apps released
before dual-arch support can still auto-update. The v0.1.x updater picks the
DMG matching its CPU; an Intel app never falls back to the arm64 legacy file.

## Release flow

1. Push a tag `vX.Y.Z` (v2 and later are the Swift app).
2. CI builds both macOS apps in a matrix:
   - `macos-15` → arm64
   - `macos-15-intel` → x64
3. Each job builds the OpenConnect engine from pinned sources with
   `-mmacosx-version-min=14.0` (see below), bundles it into the `.app`, and
   builds the app with XcodeGen + `xcodebuild` (`scripts/build-macos-app.sh`),
   and builds one DMG. Before that, the `test` job runs
   `swift test --package-path GateLinkKit`.
4. On tags, the `Sign macOS DMG for auto-update` step produces:
   - `dist/GateLink-arm64.dmg.sig` and `.sha256` (also copied to the legacy
     `GateLink.dmg.sig` / `.sha256`)
   - `dist/GateLink-x64.dmg.sig` and `.sha256`
5. The release job uploads both DMGs, both signatures, both checksums, the
   legacy arm64 copy, and the two zips.
6. A v0.1.x app downloads the DMG for its own CPU, computes SHA-256, verifies
   the signature with the pinned key, checks the bundle ID and code signature,
   then swaps the bundle with rollback.

Local signing:

```bash
./scripts/sign-release.sh dist/GateLink-arm64.dmg .secrets/gatelink-release.key
./scripts/sign-release.sh dist/GateLink-x64.dmg .secrets/gatelink-release.key
```

## Key rotation

1. Generate a new RSA-3072 key:
   ```bash
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out new.key
   openssl rsa -in new.key -pubout
   ```
2. Only v0.1.x apps pin the key (`ReleaseSignature.cs` in the .NET history);
   rotating it means those installs must update manually.
3. Update the `GATELINK_RELEASE_KEY` secret.
4. Ship a release signed with the old key first, or require a manual update.

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

The workflow uses `macos-15` (arm64) and `macos-15-intel` (x64). The runner
version no longer determines the engine's deployment target, so moving to
newer runners only changes the build toolchain; keep the `MAX=14.0` check.

macOS 12–13 still needs a separate build: lower `LSMinimumSystemVersion`, set
`TARGET` in `scripts/build-openconnect-engine.sh` (and `-target` in
`project.yml`), and use an SDK that supports that target.

## Notarization

The current app is **ad-hoc signed**, not Developer ID signed or notarized.
Gatekeeper rejects it on first launch unless the user explicitly allows it. For
public distribution, sign with a Developer ID Application certificate and
notarize with `notarytool`; the update signature is independent of Gatekeeper
and remains required.


## Upgrading from the .NET app (v0.1.x)

- The Swift app keeps the bundle ID `com.gatelink.app` and the helper version
  (`4`), so an installed helper keeps working. If the old app never installed
  the v4 helper (builds before the hardening release), the first Connect
  installs it and replaces the old NOPASSWD sudoers rule.
- The Swift app does not read the old vault (`vault.enc`). Users add their 2FA
  account again and enter the VPN password once.
- The old Open at Login LaunchAgent is removed on first launch; the setting
  now uses `SMAppService`.
- Delete `~/gatelink-auth.log` from very old builds; it may contain a session
  cookie.
