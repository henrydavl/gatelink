# GateLink — Product Requirements Document

| | |
|---|---|
| Product | GateLink: GlobalProtect VPN client with built-in TOTP 2FA |
| Upstream | `abdullahPrasetio/gatelink` (fork: `henrydavl/gatelink`) |
| Baseline | `main` @ `759b0f4` |
| Platforms | macOS 14+ (arm64, x64), Windows 10/11 x64 |
| Status | Early product: working build and auth flow, real-gateway handshake not verified by the authors |

This document describes the product as it exists and the requirements it is
built against. Items marked **Gap** are behaviours the code or docs promise
but do not yet deliver; they are candidates for contribution.

> **v2 (Swift) note.** Requirement IDs below were written against the .NET
> app. The Swift rewrite closes VPN-12 (auto-reconnect), part of ACC-8 (a
> Switch Account menu) and the double-connect bug, and replaces `expect` with a
> native PTY. Out of scope for v2: UPD-1/2 (in-app updater) and all Windows
> items (PRV-4, APP-5 Windows, UPD-4). Architecture section 6 is superseded by
> the layout table in the README.

## 1. Problem

Connecting to a GlobalProtect gateway that enforces password + TOTP usually
means: open the official client, type the password, open an authenticator app
on the phone, read a 6-digit code, type it before it expires. The official
client is also heavy, and on macOS it ships kernel/system extensions some users
prefer to avoid.

## 2. Goal

One-tap VPN connect from the menu bar/tray: the app holds the TOTP seed and the
VPN password in a biometric-protected vault, generates the code itself, and
drives the open-source OpenConnect engine for the GlobalProtect protocol.

### Non-goals

- Implementing the GlobalProtect protocol (OpenConnect does that).
- SAML / browser-based SSO login.
- Being a general-purpose authenticator app for non-VPN accounts.
- Server-side or admin features.
- Linux desktop builds (Core runs on Linux, the UI does not ship for it).

## 3. Users

| Persona | Need |
|---------|------|
| Employee on a GP gateway with TOTP | Connect quickly several times a day without a phone |
| Developer / IT power user | Lightweight client, inspectable, no vendor agent |
| Maintainer | Ship signed macOS/Windows builds from CI with safe auto-update |

## 4. Functional requirements

### 4.1 Account (2FA) management

| ID | Requirement | Status |
|----|-------------|--------|
| ACC-1 | Add an account by decoding an `otpauth://totp` QR from an image file | Done |
| ACC-2 | Add an account from a pasted `otpauth://` URI | Done |
| ACC-3 | Add an account from a raw Base32 secret with an optional label | Done |
| ACC-4 | Support digits, period and SHA1/SHA256/SHA512 from the URI (RFC 6238) | Done |
| ACC-5 | Delete an account after vault unlock | Done |
| ACC-6 | Show account details without exposing the seed | Done |
| ACC-7 | Store multiple accounts | Done (storage) |
| ACC-8 | Let the user choose which account to display/use | **Gap**: only the first account is shown; selection is implicit by typed username |
| ACC-9 | Edit an existing account (label, username) | **Gap** |
| ACC-10 | Scan a QR from the screen or camera | **Gap** (file only) |

### 4.2 OTP

| ID | Requirement | Status |
|----|-------------|--------|
| OTP-1 | Generate TOTP locally with a live countdown | Done |
| OTP-2 | Mask the code by default; reveal requires vault unlock | Done |
| OTP-3 | Copy the current code after unlock | Done |
| OTP-4 | Stop generating and drop the seed from memory when the vault relocks | Done |

### 4.3 Connection

| ID | Requirement | Status |
|----|-------------|--------|
| VPN-1 | User enters the Portal (gateway host); nothing is hard-coded | Done |
| VPN-2 | Validate the Portal as a hostname/IPv4 before any privileged call | Done |
| VPN-3 | Remember the last Portal across launches | Done (README still says "every launch": **docs gap**) |
| VPN-4 | Authenticate with `--usergroup=gateway`, sending password+OTP concatenated on one prompt | Done |
| VPN-5 | Parse the WebVPN cookie and server-cert fingerprint, refuse to start without a valid fingerprint | Done |
| VPN-6 | Start the tunnel with the cookie on stdin and pinned `--servercert` | Done |
| VPN-7 | Report Connected only after openconnect prints an established line (≤30 s) | Done |
| VPN-8 | Bound the login phase (90 s) and surface actionable error text | Done |
| VPN-9 | Disconnect cleanly | Done |
| VPN-10 | Adopt a tunnel left running from a previous app session | Done |
| VPN-11 | Detect tunnel death (exit event + 15 s health check) and return to Idle | Done |
| VPN-12 | Auto-reconnect after the tunnel process exits (`MaxReconnectAttempts = 3`) | **Gap**: constant and `Reconnecting` phase exist but are never used |
| VPN-13 | Support portals with a separate OTP prompt (not concatenated) | **Gap**: expect script answers one prompt only |
| VPN-14 | Support portal → gateway selection (multiple gateways) | **Gap**: always forces gateway login |
| VPN-15 | Send a HIP report reflecting real FileVault/firewall/Time Machine state | Done on macOS; **Gap** on Windows |

### 4.4 Vault and credentials

| ID | Requirement | Status |
|----|-------------|--------|
| VLT-1 | Encrypt seed + VPN password at rest (macOS AES-256-GCM file, key in Keychain with app-only ACL; Windows DPAPI CurrentUser) | Done |
| VLT-2 | Keep non-secret metadata readable without a prompt | Done |
| VLT-3 | One biometric unlock opens a 1-minute sliding window shared by reveal, copy, connect | Done |
| VLT-4 | Fill the saved password into the form on demand | Done |
| VLT-5 | Opt-in auto-unlock at launch | Done |
| VLT-6 | Migrate legacy Keychain items once | Done |
| VLT-7 | Configurable relock window | **Gap** (hard-coded 1 min) |

### 4.5 Privilege boundary

| ID | Requirement | Status |
|----|-------------|--------|
| PRV-1 | macOS: tunnel runs only through a root-owned wrapper with fixed argv; sudoers authorizes only that wrapper | Done |
| PRV-2 | Wrapper validates host/fingerprint and verifies a pid belongs to the bundled openconnect before killing it | Done |
| PRV-3 | One-time helper install from the app via the native admin prompt; uninstall supported | Done |
| PRV-4 | Windows: run openconnect behind a privileged service so the UI is not elevated | **Gap**: whole app runs as Administrator |

### 4.6 App shell

| ID | Requirement | Status |
|----|-------------|--------|
| APP-1 | Menu-bar (macOS, no Dock icon) / tray (Windows) popover | Done |
| APP-2 | Phase-coloured status line and button label | Done |
| APP-3 | Hide credential form while connected | Done |
| APP-4 | Requirements checklist with fix hints | Done |
| APP-5 | Open at Login | Done on macOS; **Gap** on Windows |
| APP-6 | Crash safety: unhandled exceptions logged to `~/gatelink-crash.log`, never abort | Done |

### 4.7 Update and release

| ID | Requirement | Status |
|----|-------------|--------|
| UPD-1 | Check GitHub Releases at launch, show "New update" | Done |
| UPD-2 | macOS: download the arch-specific DMG, verify SHA-256 + RSA-SHA256 signature with the pinned key, verify bundle ID and code signature, swap with rollback | Done |
| UPD-3 | Unsigned release → open the release page, never auto-install | Done |
| UPD-4 | Windows: in-app install | **Gap** (opens release page) |
| REL-1 | CI: tests on Linux, Windows exe + Inno installer, macOS arm64 + x64 DMGs | Done |
| REL-2 | Bundled engine built from pinned sources with `minos ≤ 14.0`, checked in CI | Done |
| REL-3 | Developer ID signing + notarization (macOS), Authenticode (Windows) | **Gap** |

## 5. Non-functional requirements

| Area | Requirement |
|------|-------------|
| Security | No secret (seed, password, cookie) in logs, settings, URLs or metadata. Tunnel log is `0600`. No auth transcript on disk. |
| Security | Every value crossing into root is validated in the app **and** in the wrapper. |
| Security | Release signing key never in the repo; CI secret `GATELINK_RELEASE_KEY` only. |
| Reliability | Background threads (Process.Exited, health monitor, dispatcher posts) must not throw into the runtime. |
| Compatibility | macOS 14 minimum, enforced by `LSMinimumSystemVersion` and engine `minos` checks. |
| Portability | `GateLink.Core` stays platform-neutral `net8.0` with no UI or OS-specific APIs; platform code lives in `GateLink.Desktop/Platform`. |
| Testability | Core logic is covered by xUnit tests that run headless on Linux CI. |
| Performance | Connect completes within login (≤90 s) + tunnel (≤30 s) bounds or fails with a message. |

## 6. Architecture summary

```
GateLink.Desktop (Avalonia 12, net9.0 / net9.0-windows)
  App / MainWindow / AddAccountWindow / MainViewModel
  Platform/: EncryptedFileSecretStore, VaultKeyGate, TouchIdGate,
             DpapiSecretStore, WindowsHelloGate, TunnelHelper,
             LoginItem, AutoUpdater, AppSettings
        │
GateLink.Core (net8.0, unit-tested)
  VpnSession ─ GlobalProtectAuthenticator ─ OpenConnectRunner ─ PtyAuthenticator
  GpCookie, TunnelArgs, VpnEnvironment, Prerequisites, UpdateChecker, ReleaseSignature
  Otp/: TotpGenerator, OtpAuthUri, Base32, QrDecoder
  Vault/: OtpVault, VaultCrypto, EncryptedVaultFile, ISecretStore, IBiometricGate
        │
openconnect (bundled, built from source) ── macOS: scripts/gatelink-tunnel (root)
```

Note: the README architecture table says "WPF + TrayIcon"; the UI is Avalonia.

## 7. Known risks and open questions

1. **Real handshake unverified upstream.** The authors state the full VPN
   handshake was not tested with real credentials. Any contributor change to
   the auth/tunnel path needs a test gateway.
2. **Gateway-specific assumptions.** Concatenated password+OTP and forced
   `--usergroup=gateway` match one portal. Other portals may prompt
   separately or require portal login.
3. **No license.** The upstream repo has no `LICENSE`, so reuse and
   redistribution rights are undefined (see contribution notes).
4. **Update channel is hard-wired to upstream.** `UpdateChecker.ReleasesApi`
   points at `abdullahPrasetio/gatelink`; fork builds will offer upstream
   releases, signed with upstream's key.
5. **Windows elevation.** The elevated UI parses untrusted QR images and
   gateway output.
6. **Doc drift.** README (WPF, "enter portal every launch") and
   `INSTALL-MACOS.md` (demo account, Indonesian-only) are out of date in places.

## 8. Success metrics (proposed)

- Time from click to Connected under 15 s on a reachable gateway.
- Zero secrets found in logs/settings in a release audit.
- Connect success rate on first attempt ≥ 95% for valid credentials.
- No crash reports in `~/gatelink-crash.log` per release.

## 9. Candidate roadmap (from the gaps above)

| Priority | Item | IDs |
|----------|------|-----|
| P1 | Account picker in the popover; edit account | ACC-8, ACC-9 |
| P1 | Auto-reconnect using the existing phase/constant | VPN-12 |
| P1 | Configurable credential mode (concatenated vs separate OTP prompt) | VPN-13 |
| P2 | Windows privileged service, Open at Login, HIP | PRV-4, APP-5, VPN-15 |
| P2 | Make the update repo configurable for forks | Risk 4 |
| P2 | Fix README/INSTALL doc drift; English macOS guide | Risk 6 |
| P3 | Screen/camera QR capture, configurable relock window | ACC-10, VLT-7 |
| P3 | Developer ID notarization, Authenticode | REL-3 |
