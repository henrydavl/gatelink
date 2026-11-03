# GateLink user flows

How a person uses GateLink today, as implemented on `main` (`759b0f4`). Each
flow names the code that drives it so a change to the flow can be traced to
the files it touches.

GateLink is a menu-bar (macOS) / tray (Windows) app. There is no regular
window: everything happens in a 380×560 popover anchored under the tray icon.

> **v2 (Swift) note.** These flows describe the .NET app (v0.1.x). The native
> Swift/SwiftUI app keeps the same flows with these differences:
> - Connect button becomes **Cancel** while logging in or starting the tunnel,
>   so a second click can no longer start a parallel login and kill the tunnel.
> - If the tunnel drops, it re-authenticates with a fresh OTP (3 attempts,
>   after 2/5/10 s) instead of going back to Idle. A code is never replayed:
>   a retry within the same 30 s waits for the next code.
> - Login runs in a native pseudo-terminal (no `expect`); a second password
>   prompt fails fast instead of waiting for a timeout.
> - The password field is empty with "Saved in Keychain" once a password is
>   stored; "Fill saved password" and "Auto-unlock on launch" are gone.
> - Add Account accepts dropped or pasted QR images; **… → Switch Account**
>   appears with more than one account.
> - Open at Login uses `SMAppService`; there is no in-app updater yet.
> - Windows is no longer supported.

## Screen map

```
Tray icon ──click──▶ Popover (MainWindow)
  │                   ├─ Header: logo, "GateLink", [+] Add account
  │                   ├─ Account row (only when an account exists)
  │                   │    issuer / account · 👁 reveal · ●●●●●● OTP · countdown · […] menu
  │                   │                                                    ├─ Copy code
  │                   │                                                    ├─ Account details
  │                   │                                                    ├─ Check requirements
  │                   │                                                    └─ Delete account
  │                   ├─ Status line (grey idle / blue busy / green connected / red failed)
  │                   ├─ Form (hidden while connected)
  │                   │    Portal · Username · Password [👁] · "Fill saved password"
  │                   │    ☐ Auto-unlock with biometrics on launch
  │                   ├─ [⚡ Connect | Authenticating… | Connecting… | Disconnect]
  │                   ├─ Status/error text (orange) · Add-account message (blue)
  │                   └─ Footer: version or "New update (vX)" · ☐ Open at Login · Quit
  └─ right-click menu: Open GateLink · Quit
```

Dialogs: **Add 2FA account** (`AddAccountWindow`), **Account details**,
**Requirements**, plus OS prompts (Touch ID / Keychain, Windows Hello, macOS
admin password, UAC).

---

## Flow 1 — First launch

1. User opens `GateLink.app` (macOS, ad-hoc signed → Gatekeeper asks once) or
   `GateLink.exe` (Windows, UAC elevation prompt from `app.manifest`).
2. App starts as tray-only (`ShutdownMode.OnExplicitShutdown`) and shows the
   popover once so the user sees something (`App.OnFrameworkInitializationCompleted`).
3. `MainViewModel` constructor:
   - picks the platform vault (macOS: AES-GCM file + Keychain key; Windows:
     DPAPI + Windows Hello; other: in-memory stub),
   - restores the last Portal from `settings.json`,
   - reads Open-at-Login state,
   - if OpenConnect is missing → status text *"OpenConnect not found…"*,
   - adopts a still-running tunnel from the pid file (Flow 7),
   - loads saved accounts (metadata only, no prompt),
   - checks GitHub Releases for an update in the background (Flow 9).
4. With no account: the account row is hidden and the message reads
   *"No account yet. Tap + to add your 2FA account."*

## Flow 2 — Add a 2FA account

Entry: **[+]** in the header → `AddAccountWindow`.

**2a. From a QR image**
1. **Choose QR image…** → file picker (png/jpg/gif/bmp/webp/tiff/heic, or All files).
2. `QrDecoder.DecodeOtpAuthFile` decodes the image (SkiaSharp + ZXing) into an
   `otpauth://` URI → `OtpAuthUri.Parse`.
3. Dialog closes with a `VaultEntry`; `VpnUsername` defaults to the URI's
   account label.
4. Error path: *"Could not read QR: …"* stays in the dialog.

**2b. Manual entry**
1. Paste an `otpauth://totp/...` URI **or** a raw Base32 secret.
2. For a raw secret, an optional **Label** becomes the issuer (default "VPN");
   account is set to `"account"`; digits/period/algorithm use defaults (6/30/SHA1).
3. **Add** validates (URI parse or Base32 decode); errors show inline.

**2c. Save**
1. `MainViewModel.AddEntry` asks the vault to unlock (*"Save this account"*):
   Touch ID / Keychain prompt on macOS, Windows Hello on Windows.
2. Cancel → *"Unlock cancelled; account not saved."*
3. Success → entry replaces any entry with the same id, becomes the displayed
   account, and is persisted. Persist failure → *"Saved in session only: …"*.

## Flow 3 — Connect (the main flow)

Entry: **⚡ Connect** (`MainViewModel.BeginConnect`).

```
Connect pressed
  ├─ already connected? ──▶ Disconnect (Flow 4)
  ├─ no account?            → "Add a 2FA account first (+)"
  ├─ OpenConnect missing?   → "Install OpenConnect"
  ├─ Username empty?        → "Enter username"
  ├─ Portal empty/invalid?  → "Enter a portal/gateway" / "Gateway must be a hostname…"
  ├─ save Portal to settings.json
  ├─ macOS: root helper installed + probe ok?
  │     no → native admin prompt runs install-tunnel-helper.sh (Flow 6)
  │          cancelled/failed → "Root helper installation failed or was cancelled…"
  ├─ pick account whose Account or VpnUsername matches the typed Username
  │     (falls back to the displayed account)
  ├─ vault unlock ("Connect to <portal>") — cancelled → "Unlock cancelled. VPN not connected."
  ├─ save username (+ password if typed) to the vault
  └─ VpnSession.ConnectWithVaultAsync
        ├─ load seed + password; no password stored → "No VPN password stored…"
        ├─ generate TOTP now (TotpGenerator)
        ├─ Phase: Authenticating
        │    openconnect --protocol=gp --usergroup=gateway -u <user> --authenticate <portal>
        │    credential sent as password+OTP concatenated (single prompt)
        │    macOS: via expect PTY (90 s timeout) · Windows: --passwd-on-stdin
        │    → parse COOKIE / FINGERPRINT (GpCookie)
        ├─ Phase: Connecting
        │    macOS: sudo -n gatelink-tunnel connect --host <portal> --fingerprint <pin>
        │    Windows: openconnect --cookie-on-stdin --servercert=<pin> … (elevated app)
        │    wait ≤30 s for "Configured as" / "Connected as" / "ESP session established"
        └─ Phase: Connected → health monitor every 15 s
```

What the user sees:
- Button label tracks the phase: *Authenticating… → Connecting… → Disconnect*.
- Status line turns green: *"Connected to <portal> since HH:mm"*.
- The form (Portal/Username/Password) is hidden while connected.

Failure messages (shown in orange under the button; phase → Failed, button → Connect):

| Cause | Message |
|-------|---------|
| Wrong password/OTP | *Login failed: …* / *Login failed. Check username, password and OTP.* |
| Gateway silent | *Login timed out after 90 seconds…* |
| Engine built for newer macOS | *OpenConnect is incompatible with this macOS…* |
| No fingerprint from gateway | *The gateway did not return a valid certificate fingerprint…* |
| sudo rule missing | *Root tunnel helper missing or not authorized (…)* |
| Tunnel never came up | *Tunnel did not establish: …* |

## Flow 4 — Disconnect

1. While connected the button reads **Disconnect**.
2. `VpnSession.DisconnectAsync`: Phase Disconnecting → stop health monitor →
   stop tunnel (macOS: `sudo -n gatelink-tunnel stop`, which verifies the pid
   is the bundled openconnect) → Phase Idle.
3. Form reappears; status line *"Not connected"*.

## Flow 5 — View / copy / manage the OTP

- **Reveal** (eye): first reveal unlocks the vault; the code then updates every
  second with a countdown. Hiding needs no auth.
- **Copy code** (… menu): unlocks if needed, copies the current code, shows
  *"Code copied"*.
- **Auto-relock**: the vault stays unlocked for a 1-minute sliding window
  (`RelockAfter`). When it expires the generator is dropped and the code masks
  itself again.
- **Account details**: issuer, account, digits, period, algorithm (never the seed).
- **Delete account**: unlock → remove from vault → show the next account, or
  *"Account deleted. Tap + to add one."*

Only the first saved account is shown at startup; switching between accounts
happens implicitly by typing a username that matches another account.

## Flow 6 — One-time root helper install (macOS)

Trigger: first Connect, or helper version ≠ `4`, or the sudo probe fails.

1. Status text explains the helper.
2. `osascript … with administrator privileges` runs
   `install-tunnel-helper.sh --user <user>` → macOS admin password prompt.
3. Script copies openconnect, dylibs, `vpnc-script`, `hipreport.sh` and the
   wrapper to `/usr/local/libexec/gatelink/` (root:wheel) and writes
   `/etc/sudoers.d/gatelink` allowing only that wrapper, validated with `visudo -c`.
4. App re-probes with `sudo -n gatelink-tunnel version` and continues Flow 3.

Manual alternative: `./scripts/install-tunnel-helper.sh --user "$USER"`;
removal: `--uninstall`.

## Flow 7 — Quit and relaunch while connected

1. **Quit** (footer or tray menu) detaches the UI and locks the vault but
   **leaves the tunnel running** (`VpnSession.Detach`).
2. On next launch `AdoptExistingTunnel` reads the pid file; if the process is
   alive the app shows *Connected* and resumes health checks.
3. If the tunnel process dies (detected by exit event or the 15 s health
   check), the app returns to Idle. It does **not** reconnect by itself;
   openconnect's own `--reconnect-timeout=300` covers short network drops.

## Flow 8 — Password convenience

- **Fill saved password**: unlock → load stored password into the field
  (masked) → *"Saved password loaded."*, or *"No saved password…"*.
- **Auto-unlock with biometrics on launch** (opt-in, saved in `settings.json`):
  at launch, prompt once and fill the password.
- Leaving Password blank on Connect means "use the stored one".

## Flow 9 — Update

1. At launch `UpdateChecker` queries
   `api.github.com/repos/abdullahPrasetio/gatelink/releases/latest`.
2. If newer, the footer shows orange **New update (vX.Y.Z)**.
3. Click → macOS: download the DMG for the CPU arch, verify SHA-256 + RSA
   signature against the pinned key, check bundle ID and code signature, swap
   the bundle with rollback. Missing signature → open the release page instead.
   Windows: open the release page.

## Flow 10 — Check requirements

… menu → **Check requirements** shows a checklist from `Prerequisites.Check`:
OpenConnect, `expect`, root tunnel helper, HIP report script (macOS) or
Administrator (Windows), each with a fix hint.

## Flow 11 — Open at Login

Footer checkbox. macOS: writes/removes a LaunchAgent. Windows: not implemented
yet (checkbox has no effect).

---

## Platform differences that change the flow

| Step | macOS | Windows |
|------|-------|---------|
| Launch | Gatekeeper warning (ad-hoc signed) | UAC prompt every launch (runs elevated) |
| Unlock | Touch ID + Keychain user-presence | Windows Hello; DPAPI-only if Hello unavailable |
| Login phase | `expect` PTY | stdin pipe |
| Tunnel | root helper via `sudo -n` | app itself (elevated) |
| HIP report | `hipreport.sh` via `--csd-wrapper` | not wired |
| Open at Login | LaunchAgent | not implemented |
| Update | in-app verified install | opens release page |
