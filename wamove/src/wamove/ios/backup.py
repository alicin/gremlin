from __future__ import annotations

import hashlib
import os
import plistlib
import shutil
import sqlite3
import struct
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.keywrap import aes_key_unwrap, aes_key_wrap
from pyiosbackup.keybag import Keybag
from pyiosbackup.manifest_plist import ManifestPlist

WA_DOMAIN = "AppDomainGroup-group.net.whatsapp.WhatsApp.shared"
CHATSTORAGE = "ChatStorage.sqlite"
FILE = 1
DIRECTORY = 2
ZERO_IV = b"\x00" * 16
CHUNK = 1 << 20


class BackupError(Exception):
    pass


def file_id(domain: str, relative_path: str) -> str:
    return hashlib.sha1(f"{domain}-{relative_path}".encode()).hexdigest()


def clone_tree(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if subprocess.run(["cp", "-Rc", str(src), str(dst)], capture_output=True).returncode:
        shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(src, dst)


def is_encrypted(path: Path) -> bool:
    return bool(plistlib.loads((path / "Manifest.plist").read_bytes()).get("IsEncrypted"))


def _archive(blob: bytes) -> tuple[dict, list, dict]:
    plist = plistlib.loads(blob)
    objects = plist["$objects"]
    return plist, objects, objects[plist["$top"]["root"].data]


def _deref(objects: list, value: object) -> object:
    return objects[value.data] if isinstance(value, plistlib.UID) else value


def mbfile(blob: bytes) -> dict:
    _, objects, root = _archive(blob)
    fields = {k: _deref(objects, v) for k, v in root.items() if k != "$class"}
    key = fields.get("EncryptionKey")
    if isinstance(key, dict):
        fields["EncryptionKey"] = key.get("NS.data")
    return fields


def _set_object(objects: list, root: dict, field: str, value: object) -> None:
    ref = root.get(field)
    if isinstance(ref, plistlib.UID):
        objects[ref.data] = value
    else:
        objects.append(value)
        root[field] = plistlib.UID(len(objects) - 1)


def clone_mbfile(template: bytes, *, relative_path: str, size: int, inode: int, mtime: int,
                 digest: bytes | None, key: bytes | None) -> bytes:
    plist, objects, root = _archive(template)
    root["Size"] = size
    root["InodeNumber"] = inode
    for stamp in ("LastModified", "LastStatusChange", "Birth"):
        if stamp in root:
            root[stamp] = mtime
    _set_object(objects, root, "RelativePath", relative_path)
    if digest is None:
        root.pop("Digest", None)
    else:
        _set_object(objects, root, "Digest", digest)
    if key is None:
        root.pop("EncryptionKey", None)
    else:
        current = _deref(objects, root.get("EncryptionKey"))
        if isinstance(current, dict) and "NS.data" in current:
            current["NS.data"] = key
        else:
            objects.append({"NS.data": key, "$class": plistlib.UID(len(objects) + 1)})
            objects.append({"$classname": "NSMutableData", "$classes": ["NSMutableData", "NSData", "NSObject"]})
            root["EncryptionKey"] = plistlib.UID(len(objects) - 2)
    return plistlib.dumps(plist, fmt=plistlib.FMT_BINARY)


@dataclass
class Entry:
    file_id: str
    relative_path: str
    flags: int
    blob: bytes | None


class Backup:
    def __init__(self, path: Path, password: str | None = None):
        self.path = path
        if not (path / "Manifest.db").is_file():
            raise BackupError(f"{path} is not an iPhone backup")
        manifest = plistlib.loads((path / "Manifest.plist").read_bytes())
        self.encrypted = bool(manifest.get("IsEncrypted"))
        self.written: set[str] = set()
        self.keybag: Keybag | None = None
        if self.encrypted:
            if not password:
                raise BackupError("this iPhone backup is encrypted, so its backup password is needed")
            try:
                self.keybag = Keybag.from_manifest(ManifestPlist(manifest), password)
            except Exception as e:
                raise BackupError("the backup password is wrong") from e
            wrapped = manifest["ManifestKey"]
            self.manifest_key = aes_key_unwrap(self.keybag.get_key(struct.unpack("<I", wrapped[:4])[0]), wrapped[4:])
            plain = self._cbc((path / "Manifest.db").read_bytes(), decrypt=True)
            self.padded = len(plain) % 512 != 0
            if self.padded:
                plain = plain[:-plain[-1]]
            self.db_path = path.parent / f".{path.name}-Manifest.db"
            self.db_path.write_bytes(plain)
        else:
            self.db_path = path / "Manifest.db"
        self.conn = sqlite3.connect(self.db_path)
        self.next_inode = self._max_inode() + 1

    def __enter__(self) -> Backup:
        return self

    def __exit__(self, kind, value, traceback) -> None:
        if kind is None:
            self.save()
        else:
            self.close()

    def _cbc(self, data: bytes, *, decrypt: bool) -> bytes:
        cipher = Cipher(algorithms.AES(self.manifest_key), modes.CBC(ZERO_IV))
        worker = cipher.decryptor() if decrypt else cipher.encryptor()
        return worker.update(data) + worker.finalize()

    def _max_inode(self) -> int:
        highest = 1_000_000
        for (blob,) in self.conn.execute("SELECT file FROM Files WHERE file IS NOT NULL"):
            try:
                highest = max(highest, int(mbfile(blob).get("InodeNumber") or 0))
            except Exception:
                continue
        return highest

    def payload_path(self, fid: str) -> Path:
        return self.path / fid[:2] / fid

    def get(self, relative_path: str, domain: str = WA_DOMAIN) -> Entry | None:
        row = self.conn.execute(
            "SELECT fileID, relativePath, flags, file FROM Files WHERE domain=? AND relativePath=?",
            (domain, relative_path)).fetchone()
        return Entry(*row) if row else None

    def count(self, domain: str = WA_DOMAIN) -> int:
        return self.conn.execute("SELECT COUNT(*) FROM Files WHERE domain=?", (domain,)).fetchone()[0]

    def read(self, relative_path: str, target: Path, domain: str = WA_DOMAIN) -> bool:
        entry = self.get(relative_path, domain)
        if entry is None or entry.flags != FILE or entry.blob is None:
            return False
        info = mbfile(entry.blob)
        payload = self.payload_path(entry.file_id)
        if not payload.exists():
            if not info.get("Size"):
                target.write_bytes(b"")
                return True
            raise BackupError(f"{relative_path} is listed in the backup but its data is missing")
        data = payload.read_bytes()
        if self.encrypted:
            data = self.keybag.decrypt(data, info["EncryptionKey"])[:info["Size"]]
        target.write_bytes(data)
        return True

    def _template(self, flags: int, domain: str, prefer: str = "") -> bytes:
        row = self.conn.execute(
            "SELECT file FROM Files WHERE domain=? AND flags=? AND file IS NOT NULL AND relativePath LIKE ? "
            "ORDER BY relativePath DESC LIMIT 1", (domain, flags, prefer + "%")).fetchone()
        if row:
            return row[0]
        if prefer:
            return self._template(flags, domain)
        raise BackupError(f"the backup has no {'file' if flags == FILE else 'folder'} in {domain} to model on")

    def _inode(self) -> int:
        self.next_inode += 1
        return self.next_inode - 1

    def _ensure_parents(self, relative_path: str, domain: str) -> None:
        parts = relative_path.split("/")[:-1]
        for depth in range(1, len(parts) + 1):
            folder = "/".join(parts[:depth])
            if self.get(folder, domain):
                continue
            blob = clone_mbfile(self._template(DIRECTORY, domain, "Message/Media/"), relative_path=folder, size=0,
                                inode=self._inode(), mtime=int(time.time()), digest=None, key=None)
            self.conn.execute("INSERT INTO Files (fileID, domain, relativePath, flags, file) VALUES (?,?,?,?,?)",
                              (file_id(domain, folder), domain, folder, DIRECTORY, blob))

    def _store(self, source: Path, target: Path, protection: int) -> tuple[bytes | None, bytes, int]:
        digest = hashlib.sha1()
        size = 0
        key = None
        encryptor = padder = None
        if self.encrypted:
            file_key = os.urandom(32)
            key = struct.pack("<I", protection) + aes_key_wrap(self.keybag.get_key(protection), file_key)
            encryptor = Cipher(algorithms.AES(file_key), modes.CBC(ZERO_IV)).encryptor()
            padder = padding.PKCS7(128).padder()
        with source.open("rb") as src, target.open("wb") as dst:
            for chunk in iter(lambda: src.read(CHUNK), b""):
                size += len(chunk)
                out = encryptor.update(padder.update(chunk)) if encryptor else chunk
                digest.update(out)
                dst.write(out)
            if encryptor:
                out = encryptor.update(padder.finalize()) + encryptor.finalize()
                digest.update(out)
                dst.write(out)
        return key, digest.digest(), size

    def put(self, relative_path: str, source: Path, domain: str = WA_DOMAIN) -> None:
        self._ensure_parents(relative_path, domain)
        existing = self.get(relative_path, domain)
        if existing and existing.flags == FILE and existing.blob:
            template = existing.blob
        else:
            template = self._template(FILE, domain, "Message/Media/")
        info = mbfile(template)
        fid = file_id(domain, relative_path)
        target = self.payload_path(fid)
        target.parent.mkdir(exist_ok=True)
        staging = target.with_name(target.name + ".part")
        key, digest, size = self._store(source, staging, int(info.get("ProtectionClass") or 3))
        staging.replace(target)
        inode = int(info["InodeNumber"]) if existing and info.get("InodeNumber") else self._inode()
        blob = clone_mbfile(template, relative_path=relative_path, size=size, inode=inode, mtime=int(time.time()),
                            digest=digest if "Digest" in info else None, key=key)
        self.conn.execute(
            "INSERT OR REPLACE INTO Files (fileID, domain, relativePath, flags, file) VALUES (?,?,?,?,?)",
            (fid, domain, relative_path, FILE, blob))
        self.written.add(fid)

    def prune(self, domain: str = WA_DOMAIN) -> None:
        keep = {r[0] for r in self.conn.execute("SELECT fileID FROM Files WHERE domain=?", (domain,))}
        self.conn.execute("DELETE FROM Files WHERE domain<>?", (domain,))
        for bucket in self.path.iterdir():
            if bucket.is_dir() and len(bucket.name) == 2:
                for payload in bucket.iterdir():
                    if payload.name not in keep:
                        payload.unlink()
                if not any(bucket.iterdir()):
                    bucket.rmdir()

    def check(self, domain: str = WA_DOMAIN) -> list[str]:
        problems: list[str] = []
        rows = self.conn.execute(
            "SELECT fileID, relativePath, flags, file FROM Files WHERE domain=?", (domain,)).fetchall()
        paths = {r[1] for r in rows}
        if "" not in paths:
            problems.append("the WhatsApp folder itself is missing from the backup")
        for fid, relative_path, flags, blob in rows:
            parent = relative_path.rsplit("/", 1)[0] if "/" in relative_path else ""
            if relative_path and parent not in paths:
                problems.append(f"{relative_path}: its folder is missing from the backup")
            if flags != FILE or blob is None:
                continue
            size = int(mbfile(blob).get("Size") or 0)
            payload = self.payload_path(fid)
            if not payload.exists():
                if size:
                    problems.append(f"{relative_path}: data missing")
                continue
            if fid in self.written:
                expected = (size // 16 + 1) * 16 if self.encrypted else size
                if payload.stat().st_size != expected:
                    problems.append(f"{relative_path}: stored {payload.stat().st_size} bytes, expected {expected}")
        return problems

    def save(self) -> None:
        self.conn.commit()
        self.conn.close()
        if self.encrypted:
            plain = self.db_path.read_bytes()
            if self.padded:
                padder = padding.PKCS7(128).padder()
                plain = padder.update(plain) + padder.finalize()
            (self.path / "Manifest.db").write_bytes(self._cbc(plain, decrypt=False))
            self.db_path.unlink()

    def close(self) -> None:
        self.conn.rollback()
        self.conn.close()
        if self.encrypted:
            self.db_path.unlink(missing_ok=True)
