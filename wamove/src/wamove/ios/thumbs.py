from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

SIDE = 72


def dimensions(source: str) -> tuple[int, int] | None:
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", source],
                         capture_output=True, text=True).stdout
    width, height = re.search(r"pixelWidth: (\d+)", out), re.search(r"pixelHeight: (\d+)", out)
    return (int(width.group(1)), int(height.group(1))) if width and height else None


def image(source: str, target: Path) -> tuple[int, int] | None:
    size = dimensions(source)
    if not size:
        return None
    side = str(min(size))
    steps = (["sips", "-s", "format", "jpeg", "-c", side, side, source, "--out", str(target)],
             ["sips", "-z", str(SIDE), str(SIDE), str(target)])
    for step in steps:
        if subprocess.run(step, capture_output=True).returncode:
            target.unlink(missing_ok=True)
            return None
    return size if target.is_file() else None


def video(source: str, target: Path) -> bool:
    ffmpeg = shutil.which("ffmpeg") or shutil.which("/opt/homebrew/bin/ffmpeg")
    if not ffmpeg:
        return False
    done = subprocess.run([ffmpeg, "-v", "error", "-y", "-i", source, "-frames:v", "1", "-vf",
                           f"crop=min(iw\\,ih):min(iw\\,ih),scale={SIDE}:{SIDE}", "-f", "image2", "-c:v", "mjpeg",
                           "-q:v", "4", str(target)], capture_output=True)
    return done.returncode == 0 and target.is_file()
