from __future__ import annotations

import asyncio
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from pymobiledevice3.exceptions import NoDeviceConnectedError, PairingError
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.mobilebackup2 import Mobilebackup2Service


class DeviceError(Exception):
    pass


@dataclass
class Phone:
    udid: str
    name: str
    ios: str
    encrypts_backups: bool
    used_bytes: int | None
    find_my: bool | None


def _progress(label: str) -> Callable[[float], None]:
    def show(percent: float) -> None:
        sys.stdout.write(f"\r  {label} {percent:5.1f}%")
        sys.stdout.flush()
        if percent >= 100:
            sys.stdout.write("\n")
    return show


async def _lockdown(udid: str | None):
    try:
        return await create_using_usbmux(serial=udid)
    except NoDeviceConnectedError as e:
        raise DeviceError("no iPhone found: plug it in and unlock it") from e
    except PairingError as e:
        raise DeviceError("the iPhone does not trust this Mac yet: unlock it and tap Trust") from e


async def _service(lockdown) -> Mobilebackup2Service:
    for attempt in range(3):
        service = Mobilebackup2Service(lockdown)
        try:
            await service.connect()
            return service
        except Exception:
            if attempt == 2:
                raise
            await asyncio.sleep(1.5)
    raise DeviceError("could not reach the iPhone's backup service")


async def _optional(lockdown, domain: str | None, key: str | None):
    try:
        return await lockdown.get_value(domain, key)
    except Exception:
        return None


def phone(udid: str | None = None) -> Phone:
    async def go() -> Phone:
        lockdown = await _lockdown(udid)
        try:
            usage = await _optional(lockdown, "com.apple.disk_usage", None) or {}
            capacity, available = usage.get("TotalDataCapacity"), usage.get("TotalDataAvailable")
            find_my = await _optional(lockdown, "com.apple.fmip", "IsAssociated")
            return Phone(
                udid=lockdown.udid,
                name=await lockdown.get_value(key="DeviceName") or "",
                ios=await lockdown.get_value(key="ProductVersion") or "",
                encrypts_backups=bool(await _optional(lockdown, "com.apple.mobile.backup", "WillEncrypt")),
                used_bytes=capacity - available if capacity and available else None,
                find_my=None if find_my is None else bool(find_my),
            )
        finally:
            await lockdown.close()

    return asyncio.run(go())


def backup(root: Path, udid: str | None = None) -> str:
    async def go() -> str:
        lockdown = await _lockdown(udid)
        try:
            service = await _service(lockdown)
            try:
                await service.backup(full=True, backup_directory=root, progress_callback=_progress("backing up"))
            finally:
                await service.close()
            return lockdown.udid
        finally:
            await lockdown.close()

    root.mkdir(parents=True, exist_ok=True)
    return asyncio.run(go())


def restore(root: Path, source: str, password: str | None, udid: str | None = None) -> None:
    async def go() -> None:
        lockdown = await _lockdown(udid)
        try:
            service = await _service(lockdown)
            try:
                await service.restore(
                    backup_directory=root,
                    system=True,
                    reboot=True,
                    copy=False,
                    settings=True,
                    remove=False,
                    password=password or "",
                    source=source,
                    progress_callback=_progress("restoring"),
                    skip_apps=True,
                )
            finally:
                await service.close()
        finally:
            await lockdown.close()

    asyncio.run(go())
