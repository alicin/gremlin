# pluck

Pull text and colors off the screen on macOS.

- `⌘⇧1` shows the screenshot crosshair (space switches to window mode). The selected area is read with Apple's on-device text recognition, the same engine Live Text uses, and the text goes to the clipboard.
- `⌘⇧2` shows the system color loupe. The color you click goes to the clipboard as sRGB hex, e.g. `#1e1e2e`.

It is a single Swift file with no dependencies. It runs as a background agent with no Dock or menu bar icon, and uses Carbon hotkeys, so it needs no Accessibility permission.

## Install

Requires macOS 13+ and the Xcode Command Line Tools.

```sh
./install.sh
```

This builds `~/Applications/Pluck.app`, signs it ad hoc, and starts it from `~/Library/LaunchAgents/com.bunniesinc.pluck.plist` at login.

On first run macOS asks for **Screen Recording** permission, which `⌘⇧1` needs. The grant is tied to the exact binary, so if `⌘⇧1` stops finding text after you rebuild a changed version, remove Pluck from System Settings → Privacy & Security → Screen Recording and allow it again.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.bunniesinc.pluck
rm -rf ~/Applications/Pluck.app ~/Library/LaunchAgents/com.bunniesinc.pluck.plist
```
