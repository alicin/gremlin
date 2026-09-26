# wamove

Move WhatsApp chats and media from an Android phone to an iPhone that is already set up, without resetting the iPhone.

WhatsApp's own Android → iPhone transfer only works while setting up a new or erased iPhone. wamove instead:

1. copies the Android phone's encrypted chat backup and media over USB,
2. decrypts the backup with its 64-digit key,
3. backs up the iPhone and keeps a copy with only WhatsApp's data,
4. adds the Android chats and media to that copy, following the conventions of the rows WhatsApp itself wrote on the iPhone,
5. restores only WhatsApp's data to the iPhone. The rest of the phone is left as it is.

> [!WARNING]
> This uses undocumented formats and is not supported by WhatsApp or Apple. Keep the Android phone and its backup until you are happy with the result. If something goes wrong, `wamove rollback` puts back WhatsApp's data as it was before, and the full iPhone backup from step 3 stays on your Mac.

## Requirements

- macOS with the Xcode Command Line Tools, [uv](https://docs.astral.sh/uv/) and `adb` (`brew install --cask android-platform-tools`)
- Free disk space for a full iPhone backup plus the Android media

## Install

```sh
./install.sh
```

## Moving your chats

On the **Android phone**:

1. In WhatsApp, open Settings → Chats → Chat backup → End-to-end encrypted backup, turn it on and choose **Use 64-digit encryption key instead**. Save the key.
2. Tap **Back up**. A backup made before the key was set cannot be decrypted with it.
3. Turn on USB debugging (Settings → Developer options), plug the phone into the Mac and allow it.

```sh
wamove doctor
wamove pull       # the chat backup and all media
wamove decrypt    # asks for the 64-digit key
```

On the **iPhone**:

1. Install WhatsApp and register it with the same number. This signs WhatsApp out on the Android phone, which is expected. Skip restoring from iCloud.
2. Send and receive a message and a photo, so the database contains rows to learn from.
3. Turn on Airplane mode and turn off Wi-Fi, so no new messages arrive until the restore is done. They wait on WhatsApp's servers and arrive afterwards.
4. Turn off Find My (Settings → your name → Find My). Restores are refused while it is on.

```sh
wamove backup     # full iPhone backup, then a WhatsApp-only copy; asks for the backup password if backups are encrypted
wamove inspect    # optional: what is on each side
wamove build      # adds the Android chats to the WhatsApp-only copy
wamove restore    # the iPhone restarts when done
```

After the restart, finish the setup screens if they appear, open WhatsApp, then turn Airplane mode off and Find My back on.

If the result is not right, `wamove rollback` restores the untouched WhatsApp-only copy.

Everything wamove copies stays in `~/wamove` (`--work` to change it). It holds your decrypted chats: delete it when you are done.

## What moves

Text messages, photos, videos, voice notes, audio, documents, GIFs, stickers, locations and contact cards, in one-to-one chats and groups, with the right senders and dates. System messages ("X joined"), deleted-message markers, call logs, reactions, polls, status updates and channels are not moved.

## Development

```sh
uv run --group dev pytest
```

## Credits

wamove started from [wabridge](https://github.com/parvesh-rm/wabridge) by Parvesh Kumar (GPL-3.0-or-later), whose ChatStorage writer, crypt15 reader and msgstore parser it adapts. Changes made in September 2026: a WhatsApp-only restore instead of a full one, encrypted backup support, corrected media paths, LID-aware group members and a trimmed command line. It also builds on:

- [green2blue](https://github.com/discordwell/green2blue) (MIT) for how new files are added to an encrypted backup
- [Jalquin's migration notes](https://github.com/Jalquin/whatsapp-android-ios-migration-notes) for the WhatsApp-only restore and the media path layout
- [oath](https://github.com/rohancodesss/oath) for the backup record rules
- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) for talking to the iPhone

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
