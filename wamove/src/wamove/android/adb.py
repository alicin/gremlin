from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

ROOTS = (
    "/sdcard/Android/media/com.whatsapp/WhatsApp",
    "/storage/emulated/0/Android/media/com.whatsapp/WhatsApp",
)
MEDIA_DIRS = (
    "WhatsApp Images",
    "WhatsApp Video",
    "WhatsApp Voice Notes",
    "WhatsApp Audio",
    "WhatsApp Documents",
    "WhatsApp Animated Gifs",
    "WhatsApp Stickers",
    "WhatsApp Video Notes",
)
FALLBACK_ADB = ("/opt/homebrew/bin/adb", os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"))


class AdbError(Exception):
    pass


def _adb() -> str:
    exe = shutil.which("adb") or next((p for p in FALLBACK_ADB if os.path.isfile(p)), None)
    if not exe:
        raise AdbError("adb not found; install it with: brew install --cask android-platform-tools")
    return exe


def run(*args: str, check: bool = True) -> str:
    r = subprocess.run([_adb(), *args], capture_output=True, text=True, errors="replace")
    if check and r.returncode:
        raise AdbError(f"adb {' '.join(args)}: {(r.stderr or r.stdout).strip()}")
    return r.stdout


def shell(command: str) -> str:
    return run("shell", command, check=False)


def device() -> str:
    rows = [line.split() for line in run("devices", "-l").splitlines()[1:] if line.strip()]
    ready = [row for row in rows if row[1] == "device"]
    if not rows:
        raise AdbError("no Android phone found: turn on USB debugging, plug it in and allow this Mac")
    if not ready:
        raise AdbError(f"the Android phone is '{rows[0][1]}': unlock it and accept the USB debugging prompt")
    if len(ready) > 1:
        raise AdbError("more than one Android device is connected")
    return next((p.split(":", 1)[1] for p in ready[0] if p.startswith("model:")), ready[0][0])


def whatsapp_root() -> str:
    for root in ROOTS:
        listing = shell(f'ls "{root}/Databases" 2>/dev/null')
        if "msgstore.db.crypt15" in listing:
            return root
        if "msgstore" in listing:
            raise AdbError(
                "the phone only has an older backup format: in WhatsApp turn on Settings > Chats > Chat backup > "
                "End-to-end encrypted backup with a 64-digit key, then tap Back up"
            )
    raise AdbError("no WhatsApp backup on the phone: in WhatsApp open Settings > Chats > Chat backup and tap Back up")


def media_dirs(root: str) -> list[str]:
    return [d for d in MEDIA_DIRS if shell(f'[ -d "{root}/Media/{d}" ] && echo yes').strip() == "yes"]


def remote_bytes(path: str) -> int:
    match = re.match(r"(\d+)", shell(f'du -sk "{path}" 2>/dev/null').strip())
    return int(match.group(1)) * 1024 if match else 0


def pull(remote: str, local: Path) -> None:
    local.mkdir(parents=True, exist_ok=True)
    if subprocess.run([_adb(), "pull", "-a", remote, str(local)]).returncode:
        raise AdbError(f"adb pull {remote} failed")


def contacts() -> dict[str, str]:
    out = shell("content query --uri content://com.android.contacts/data/phones --projection display_name:data1")
    result: dict[str, str] = {}
    for line in out.splitlines():
        match = re.search(r"display_name=(.*?), data1=(.*)$", line)
        if not match:
            continue
        name, digits = match.group(1).strip(), re.sub(r"\D", "", match.group(2))
        if name and name != "NULL" and digits:
            result[digits] = name
    return result
