# gremlin

A menu bar app for small "this Mac" fixes and tools on macOS.

```
Grab Text                      ⌘⇧1
Pick Color                     ⌘⇧2
───────────────────────────────
✓ Universal Control Watcher
    Watching
    Last reset: 13:22, recovered
    Reset Universal Control Now
───────────────────────────────
✓ Start at Login
Quit Gremlin
```

- **Grab Text** (`⌘⇧1`) shows the screenshot crosshair (space switches to window mode). The selected area is read with Apple's on-device text recognition, the same engine Live Text uses, and the text goes to the clipboard.
- **Pick Color** (`⌘⇧2`) shows the system color loupe. The color you click goes to the clipboard as sRGB hex, e.g. `#1e1e2e`.
- **Universal Control Watcher** resets Universal Control when it gets stuck on another Mac (see below).

The hotkeys are always on. Switches (the checkmark items) are remembered between launches, and everything that is switched on starts when Gremlin does. Start at Login uses the system login item (System Settings → General → Login Items), so Quit Gremlin really quits.

It is a few Swift files with no dependencies. The hotkeys are Carbon hotkeys, so it needs no Accessibility permission.

## Install

Requires macOS 13+ and the Xcode Command Line Tools.

```sh
./install.sh
```

This builds `~/Applications/Gremlin.app` and starts it. If Pluck (the old hotkey-only version) is installed, it is removed.

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

`<peer>` is any 8-hex-digit device ID. The retries are ~30 s apart, so "gave up" comes a few minutes after the wake.

When a peer gives up, the watcher waits 10 s and flips the same setting as the System Settings toggle, off for 3 s and back on:

```sh
defaults -currentHost write com.apple.universalcontrol Disable -bool true
sleep 3
defaults -currentHost write com.apple.universalcontrol Disable -bool false
```

The flip makes the peer go unavailable and available again and starts a fresh initial sync. The watcher ignores that unavailable/available pair and judges the reset by the result of the new sync: the peer joining is a recovery, and giving up again is a failed reset. Failed resets back off (10 s, 1 min, 5 min), then it stops until the peer really goes away and comes back. It never resets a peer that is away, and it restarts `log stream` if it exits. If Gremlin quits mid-flip, Universal Control is switched back on at quit or on the next launch.

Resets and their results go to the menu, to a notification, and to `~/Library/Logs/Gremlin.log`.

Don't reset Universal Control any other way. `killall UniversalControl` is ignored, `launchctl kickstart -k gui/$UID/com.apple.ensemble` is refused by SIP, and `kill -9` gets it relaunched but left the other Mac holding a dead session until Universal Control was toggled on that Mac.

It is not yet proven that flipping the setting on this Mac alone gets out of a real stuck state (a manual toggle did, in under a second). Check `~/Library/Logs/Gremlin.log` the first time it fires.

## Uninstall

Turn off Start at Login, quit Gremlin, then:

```sh
rm -rf ~/Applications/Gremlin.app
defaults delete com.bunniesinc.gremlin
security delete-identity -c "Gremlin Code Signing" ~/Library/Keychains/login.keychain-db
```
