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

Prefer drag-to-install? The release also has `GateLink-arm64.dmg` and
`GateLink-x64.dmg`. With those, the app installs the tunnel helper on the
first Connect instead (one administrator prompt then).

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

1. Enter the **Portal** (for example `vpn.example.com`), your **Username** and
   **Password**. The password is saved in the Keychain after the first
   connect; afterwards leave the field empty.
2. Press **Connect**.
3. If you installed from the DMG, the first Connect asks for an
   administrator password to install GateLink's tunnel helper (the `.pkg`
   already did this). It installs to `/usr/local/libexec/gatelink` and adds a
   sudoers rule that allows only that helper.
4. Approve Touch ID. GateLink logs in with your password plus the current code
   and starts the tunnel.

While it works, the button reads **Cancel**. Once connected it reads
**Disconnect**, and the status line shows the portal and the time you
connected. If the connection drops, GateLink reconnects with a fresh code.

## 4. Everyday use

- **See or copy the code**: the eye button shows it; **… → Copy Code**
  copies it. Both need Touch ID unless you unlocked in the last minute.
- **Several accounts**: **… → Switch Account**, or type the other account's
  username.
- **Open at Login**: checkbox at the bottom of the popover.
- **Quit** leaves the VPN connected. Disconnect first if you want it off.

## 5. If something fails

Open **… → Requirements…**. It checks the bundled OpenConnect engine, the
tunnel helper and its sudoers rule, and the HIP report script, and says how to
fix each one. **Remove Tunnel Helper…** uninstalls the helper.

The tunnel log is at `~/Library/Logs/GateLink/tunnel.log`.
