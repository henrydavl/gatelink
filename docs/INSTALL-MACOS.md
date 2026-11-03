# Installing and using GateLink on macOS

## 1. Install

Download the installer for your Mac from the latest release:

| Mac | File |
|-----|------|
| Apple Silicon (M1 and later) | `GateLink-arm64.pkg` |
| Intel | `GateLink-x64.pkg` |

Check with `uname -m`: `arm64` is Apple Silicon, `x86_64` is Intel. Both need
macOS 14 or later.

Double-click the `.pkg`. It is not notarized, so macOS blocks it the first
time: open **System Settings → Privacy & Security**, press **Open Anyway**,
then run the installer. Installer asks for your administrator password once
and sets up both the app and GateLink's tunnel helper, so Connect works with
no further prompts.

GateLink lives in the menu bar (a shield icon); it has no Dock icon.

## 2. Add your 2FA account

Click the shield, then **+**:

- **QR code**: drop the QR image into the window, choose it with **Choose
  Image…**, or copy it and press **Paste Image**.
- **Manually**: paste the `otpauth://totp/…` link or the secret key, and
  optionally a name.

Check the **VPN username** and press **Add**. macOS asks for Touch ID (or your
login password) to save the secret in the Keychain.

## 3. Connect

1. Enter the **Portal** (for example `vpn.example.com`) and check your
   **Username**. Next to **Password**, press **Set…** and enter your VPN
   password (or pick it with the Passwords app). It is saved in the Keychain,
   so you do this once.
2. Press **Connect**.
3. If the tunnel helper is missing (for example after you removed it from
   Requirements), Connect asks for an administrator password to reinstall it
   to `/usr/local/libexec/gatelink`, with a sudoers rule that allows only that
   helper. The `.pkg` already installed it.
4. Approve Touch ID. GateLink logs in with your password plus the current code
   and starts the tunnel.

While it works, the button reads **Cancel**. Once connected it reads
**Disconnect**, and the status line shows the portal and the time you
connected. If the connection drops, GateLink reconnects with a fresh code.

## 4. Everyday use

- **See or copy the code**: the eye button shows it; click the code or the
  copy button beside it to copy it. Both need Touch ID unless you unlocked in
  the last minute.
- **Several accounts**: pick one from the arrows next to the account name, or
  type the other account's username. Its username fills in for you.
- **Password**: **Change…** next to Password opens the password window; its
  eye button shows what you typed.
- **Open at Login**: checkbox at the bottom of the popover.
- **Updates**: GateLink checks GitHub at launch and every 6 hours. When a
  newer release exists, **Update to vX.Y.Z** appears next to the version.
  Click it: GateLink downloads the `.pkg` for your Mac, checks its SHA-256
  against the release and that it contains GateLink at that version, asks for
  your administrator password, installs it and reopens. Installing disconnects
  the VPN. Hover the button for the release notes, right-click it to open them
  on GitHub, or use … → **Check for Updates**.
- **Quit** disconnects the VPN. So does a crash or Force Quit: the tunnel
  never outlives the app.

## 5. If something fails

Open **… → Requirements…**. It checks the bundled OpenConnect engine, the
tunnel helper and its sudoers rule, and the HIP report script, and says how to
fix each one. **Remove Tunnel Helper…** uninstalls the helper.

The tunnel log is at `~/Library/Logs/GateLink/tunnel.log`.
