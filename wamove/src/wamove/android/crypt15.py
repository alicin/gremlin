from __future__ import annotations

import hmac
import re
import zlib
from hashlib import sha256
from pathlib import Path

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

SQLITE_MAGIC = b"SQLite format 3\x00"
IV_LEN = 16


class Crypt15Error(Exception):
    pass


def parse_key(text: str) -> bytes:
    digits = re.sub(r"[\s\-:]", "", text)
    if not re.fullmatch(r"[0-9a-fA-F]{64}", digits):
        raise Crypt15Error("the key must be the 64-digit end-to-end backup key WhatsApp showed you")
    return bytes.fromhex(digits)


def derive_aes_key(root_key: bytes) -> bytes:
    prk = hmac.new(b"\x00" * 32, root_key, sha256).digest()
    return hmac.new(prk, b"backup encryption\x01", sha256).digest()


def _varint(buf: bytes, pos: int) -> tuple[int, int]:
    result = shift = 0
    while True:
        if pos >= len(buf):
            raise Crypt15Error("truncated varint")
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7
        if shift > 63:
            raise Crypt15Error("varint too long")


def _fields(buf: bytes, depth: int = 0) -> list[bytes]:
    found: list[bytes] = []
    pos = 0
    while pos < len(buf):
        tag, pos = _varint(buf, pos)
        wire = tag & 7
        if wire == 0:
            _, pos = _varint(buf, pos)
        elif wire == 1:
            pos += 8
        elif wire == 2:
            length, pos = _varint(buf, pos)
            value = buf[pos:pos + length]
            if len(value) != length:
                raise Crypt15Error("truncated field")
            pos += length
            found.append(value)
            if depth < 6 and value:
                try:
                    found.extend(_fields(value, depth + 1))
                except Crypt15Error:
                    pass
        elif wire == 5:
            pos += 4
        else:
            raise Crypt15Error(f"unsupported protobuf wire type {wire}")
        if pos > len(buf):
            raise Crypt15Error("truncated field")
    return found


def _header(data: bytes) -> tuple[int, list[bytes]]:
    length, start = _varint(data, 0)
    if not 0 < length <= 4096 or start + length > len(data):
        raise Crypt15Error("this does not look like a .crypt15 backup")
    candidates = [v for v in _fields(data[start:start + length]) if len(v) == IV_LEN]
    if not candidates:
        raise Crypt15Error("no IV found in the .crypt15 header")
    ivs = sorted(dict.fromkeys(candidates), key=lambda v: all(0x20 <= b < 0x7F for b in v))
    return start + length, ivs


def decrypt(data: bytes, root_key: bytes) -> bytes:
    offset, ivs = _header(data)
    body = data[offset:]
    gcm = AESGCM(derive_aes_key(root_key))
    for iv in ivs:
        for trailer in (0, 16):
            try:
                plain = gcm.decrypt(iv, body[:len(body) - trailer], None)
            except InvalidTag:
                continue
            if plain[:1] == b"\x78":
                try:
                    plain = zlib.decompress(plain)
                except zlib.error as e:
                    raise Crypt15Error(f"the backup decrypted but did not decompress: {e}") from e
            if plain.startswith(SQLITE_MAGIC):
                return plain
    raise Crypt15Error("the key does not open this backup; make a new backup in WhatsApp after setting the key")


def decrypt_file(src: Path, dst: Path, root_key: bytes) -> None:
    plain = decrypt(src.read_bytes(), root_key)
    tmp = dst.with_name(dst.name + ".part")
    tmp.write_bytes(plain)
    tmp.replace(dst)
