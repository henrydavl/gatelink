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
then run the installer. Installer asks for your administrator password once.

You also need the official GlobalProtect app, installed and set up with your
portal.

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

1. Check your **Username**. Next to **Password**, press **Set…** and enter your
   VPN password (or pick it with the Passwords app). It is saved in the Keychain,
   so you do this once, and again when your password changes.
2. Press **Connect**.
3. The first time, macOS asks for Accessibility permission. Turn on GateLink under
   **System Settings → Privacy & Security → Accessibility**, then press **Connect**
   again. GateLink needs it to fill in GlobalProtect's login window.
4. Approve Touch ID. GateLink opens GlobalProtect, fills in your username and your
   password plus the current code, and presses Connect once.

While it works, the button reads **Cancel**. Once connected it reads **Open
GlobalProtect**: disconnect there. When the session ends you get a notification;
click it to log in again. If a login is rejected GateLink doesn't retry, so check
your saved password before pressing Connect again.

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
  your administrator password, installs it and reopens. Hover the button for the release notes, right-click it to open them
  on GitHub, or use … → **Check for Updates**.
- **Quit** closes GateLink only. GlobalProtect stays connected.

## 5. If something fails

GateLink says which step failed. You can always log in to GlobalProtect by hand. If
**Connect** asks for Accessibility permission when it's already on, remove GateLink
from the list and add it again; this can happen after an update.
