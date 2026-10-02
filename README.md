# gremlin

A menu bar app for small "this Mac" fixes and tools on macOS.

```
Grab Text                      ⌘⇧1
Pick Color                     ⌘⇧2
Paste as Plain Text           ⌃⌥⌘V
Fix Focus                     ⌃⌥⌘F
───────────────────────────────
Keep Awake: Until 15:30        ▸
Restart                        ▸
───────────────────────────────
  Auto-Fix Lost Focus
✓ Fix Stuck Notification Center
───────────────────────────────
✓ Universal Control Watcher
    Watching
    Last reset: 13:22, recovered
    Reset Universal Control        ▸
───────────────────────────────
prime-consultant: Watching
Unpair prime-consultant
───────────────────────────────
✓ Start at Login
Quit Gremlin
```

- **Grab Text** (`⌘⇧1`) shows the screenshot crosshair (space switches to window mode). The selected area is read with Apple's on-device text recognition, the same engine Live Text uses, and the text goes to the clipboard. If the selection has a QR code or barcode in it, its content is copied instead.
- **Pick Color** (`⌘⇧2`) shows the system color loupe. The color you click goes to the clipboard as sRGB hex, e.g. `#1e1e2e`.
- **Paste as Plain Text** (`⌃⌥⌘V`) strips the formatting from the clipboard and pastes. Without Accessibility permission it only strips it, and you paste with `⌘V`.
- **Fix Focus** (`⌃⌥⌘F`) is for when the menu bar shows one app but typing goes nowhere or to another window, which happens after Space switches and with Universal Control. It does what switching away and back does: Gremlin takes focus for a moment and hands it back to the app whose window is on top, then raises that window.
- **Keep Awake** keeps the display and the Mac awake for 30 minutes to 4 hours, or until you turn it off, and lists any other apps keeping it awake.
- **Restart** restarts one of Dock, Finder, the menu bar (SystemUIServer), Control Center, Notification Center, Window Manager (Stage Manager and tiling), the clipboard (`pboard`), Universal Clipboard (`useractivityd`, then `pboard`) or iCloud Drive (`bird`), or all of them. They run as you and macOS starts them again, so no admin password is needed. Restarting the clipboard empties it.
- **Auto-Fix Lost Focus** runs Fix Focus by itself when the frontmost app has windows on screen but none of them has focus, or another app's window sits on top of them on the same display, for 3 seconds. If the problem comes back within 15 seconds of a fix, it leaves that app alone until Gremlin restarts, because some apps never report focus properly. Off by default.
- **Fix Stuck Notification Center** restarts Notification Center when it stays above 90% CPU for 30 seconds. On macOS 27.0 a banner can freeze halfway in and leave it spinning.
- **Universal Control Watcher** resets Universal Control when it gets stuck on another Mac (see below).
- **Pair Another Mac…** connects to Gremlin on your other Mac, so each can reset Universal Control on the other.

The hotkeys are always on. Switches (the checkmark items) are remembered between launches, and everything that is switched on starts when Gremlin does. Keep Awake also survives a relaunch until its time is up. Start at Login uses the system login item (System Settings → General → Login Items), so Quit Gremlin really quits.

It is a few Swift files with no dependencies. The hotkeys are Carbon hotkeys, so they need no Accessibility permission. Auto-Fix Lost Focus and the paste in Paste as Plain Text do, and macOS asks for it the first time you use them. Gremlin's log is `~/Library/Logs/Gremlin.log`.

## Install

Requires macOS 14+ and the Xcode Command Line Tools.

```sh
git clone https://github.com/alicin/gremlin.git
./gremlin/install.sh
```

Run `install.sh` again after pulling changes. It builds `~/Applications/Gremlin.app` and starts it. If Pluck (the old hotkey-only version) is installed, it is removed.

On first run macOS asks for **Screen Recording** permission, which Grab Text needs, and for permission to show notifications. The app is signed with a self-signed "Gremlin Code Signing" certificate that the installer creates in the login keychain once. The Screen Recording grant follows that certificate, so it survives rebuilds. The first build may ask to let `codesign` use the key; choose Always Allow.

## Universal Control watcher

### The bug

Seen on macOS 27.0 (26A428). When the other Mac wakes or comes back into range, Universal Control runs an "initial sync". If the other Mac isn't ready yet, all 6 retries fail. This Mac then marks the peer `valid=false` and never retries on its own. The other Mac keeps opening a connection every 60 s over AWDL, gets no answer, and hangs up, forever. It only recovers when the peer disappears and comes back, or Universal Control is toggled.

### What the watcher does

It streams Universal Control's logs as the current user:

```sh
/usr/bin/log stream --style ndjson --predicate 'process == "UniversalControl" AND category == "SYNC"'
```

- **Gave up:** `IDS <peer>: Initial Sync (Retry 6 of 6)`, then `IDS <peer>: Initial Sync Failed: …`, then `IDS <peer>: available=true, valid=false`
- **Recovered:** `In-Circle Devices: [<peer>]`
- **Peer gone:** `IDS <peer>: Device Unavailable` / `Device Lost`

`<peer>` is any 8-hex-digit device ID. How long the retries take depends on the failure. `-6722` means the other Mac didn't answer, and each retry waits up to ~30 s. `-71143` means the other Mac reset the connection during pairing verification, and all 6 retries fail within seconds.

When a peer gives up, the watcher waits 10 s and flips the same setting as the System Settings toggle, off for 3 s and back on:

```sh
defaults -currentHost write com.apple.universalcontrol Disable -bool true
sleep 3
defaults -currentHost write com.apple.universalcontrol Disable -bool false
```

The flip makes the peer go unavailable and available again and starts a fresh initial sync. The watcher ignores that unavailable/available pair and judges the reset by the result of the new sync: the peer joining is a recovery, and giving up again is a failed reset. Failed resets back off (10 s, 1 min, 5 min), then it tries again every 30 min while the peer stays stuck. It never resets a peer that is away, and it restarts `log stream` if it exits. If Gremlin quits mid-flip, Universal Control is switched back on at quit or on the next launch.

Flipping it on this Mac does not always help. On 2026-09-29 the MacBook Pro refused marvin's connections (`-71143`), three resets on marvin changed nothing, and it needed a toggle on the MacBook Pro. That is what pairing is for.

### Two Macs

Install Gremlin on both Macs and choose **Pair Another Mac…** on each within 2 minutes. Both show a 6-digit code. Click Pair on both if the codes match. The first time, macOS asks to allow Gremlin to find devices on the local network.

Once paired, the Macs talk over the local network (Bonjour, `_gremlin._tcp`, TCP port 47101), not over the AWDL link Universal Control uses. When Bonjour can't see the other Mac, Gremlin tries the addresses it last reported, which includes its Tailscale address. Only three messages exist: `status`, `reset` (flip Universal Control on the receiving Mac) and `stuck` (tell the other Mac what this one sees). Each is signed with a key agreed during pairing (Curve25519, HMAC-SHA256), with a timestamp and nonce so it can't be replayed. The key is kept in the login keychain.

Only one of the two Macs runs the resets, so they don't toggle each other at the same time. The other one reports what it sees to that Mac and waits. When a Mac logs `-71143`, the other Mac refused, so the first reset happens on the refusing Mac. Otherwise it happens on the Mac that saw the failure. The next ones go to the other Mac, then both. If the other Mac can't be reached, each Mac falls back to resetting itself.

The Reset Universal Control submenu does the same by hand: on this Mac, on the other one, or on both.

Resets and their results go to the menu, to a notification, and to `~/Library/Logs/Gremlin.log`.

Don't reset Universal Control any other way. `killall UniversalControl` is ignored, `launchctl kickstart -k gui/$UID/com.apple.ensemble` is refused by SIP, and `kill -9` gets it relaunched but left the other Mac holding a dead session until Universal Control was toggled on that Mac.

## Uninstall

Turn off Start at Login, quit Gremlin, then:

```sh
rm -rf ~/Applications/Gremlin.app
defaults delete com.bunniesinc.gremlin
security delete-generic-password -s com.bunniesinc.gremlin.peer ~/Library/Keychains/login.keychain-db
security delete-identity -c "Gremlin Code Signing" ~/Library/Keychains/login.keychain-db
```
