from __future__ import annotations

import hashlib
import os
import sqlite3
import zlib
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pyiosbackup import Backup as ReferenceBackup

from fixtures import (ALICE, BOB_LID, BOB_PN, GROUP, PASSWORD, UDID, make_backup, make_chatstorage, make_media,
                      make_msgstore)
from wamove.android import crypt15, msgstore
from wamove.cli import main
from wamove.ios import chatstorage
from wamove.ios.backup import CHATSTORAGE, DIRECTORY, WA_DOMAIN, Backup, BackupError, file_id, mbfile

KEY = "0123456789abcdef" * 4


def encrypt_crypt15(plain: bytes, trailer: bytes = b"") -> bytes:
    iv = os.urandom(16)
    header = bytes([0x08, 0x01, 0x1A, 18, 0x0A, 16]) + iv
    body = AESGCM(crypt15.derive_aes_key(crypt15.parse_key(KEY))).encrypt(iv, zlib.compress(plain), None)
    return bytes([len(header)]) + header + body + trailer


def test_crypt15_roundtrip(tmp_path: Path) -> None:
    make_msgstore(tmp_path / "msgstore.db")
    plain = (tmp_path / "msgstore.db").read_bytes()
    for trailer in (b"", os.urandom(16)):
        assert crypt15.decrypt(encrypt_crypt15(plain, trailer), crypt15.parse_key(KEY)) == plain
    with pytest.raises(crypt15.Crypt15Error):
        crypt15.decrypt(encrypt_crypt15(plain), crypt15.parse_key("f" * 64))
    with pytest.raises(crypt15.Crypt15Error):
        crypt15.parse_key("1234")


def test_parse_msgstore(tmp_path: Path) -> None:
    make_msgstore(tmp_path / "msgstore.db")
    archive = msgstore.parse(tmp_path / "msgstore.db", {"61400000002": "Alice Example"})
    chats = {c.jid: c for c in archive.chats}
    assert set(chats) == {ALICE, GROUP, BOB_PN}
    assert chats[BOB_PN].lid == BOB_LID
    assert archive.lids[BOB_PN] == BOB_LID
    assert chats[ALICE].name == "Alice Example"
    assert [m.key_id for m in chats[ALICE].messages] == ["K100", "K101", "K102", "K103", "K104", "K105", "K108",
                                                         "K109"]
    assert chats[ALICE].messages[3].kind.value == "voice"
    group = chats[GROUP]
    assert group.name == "Family"
    assert [m.sender_jid for m in group.messages] == [ALICE, BOB_PN, None]
    assert {p.jid for p in group.participants} >= {ALICE, BOB_PN}


def import_fixture(tmp_path: Path) -> tuple[Path, chatstorage.Report]:
    make_msgstore(tmp_path / "msgstore.db")
    make_media(tmp_path / "Media")
    make_chatstorage(tmp_path / CHATSTORAGE)
    archive = msgstore.parse(tmp_path / "msgstore.db")
    writer = chatstorage.Writer(tmp_path / CHATSTORAGE, archive.lids)
    report = writer.import_archive(archive, tmp_path / "Media")
    writer.close()
    return tmp_path / CHATSTORAGE, report


def test_writer(tmp_path: Path) -> None:
    database, report = import_fixture(tmp_path)
    assert chatstorage.verify(database) == []
    assert report.messages_skipped == 1
    assert report.messages_written == 11
    assert report.sessions_reused == 2
    assert report.sessions_created == 1
    assert report.media_linked == 4
    assert report.media_missing == 1
    conn = sqlite3.connect(database)
    paths = [r[0] for r in conn.execute("SELECT ZMEDIALOCALPATH FROM ZWAMEDIAITEM WHERE ZMEDIALOCALPATH IS NOT NULL")]
    assert paths and all(p.startswith(f"Media/{ALICE}/") for p in paths)
    assert all(f.relative_path.startswith("Message/Media/") for f in report.media_files)
    dates = [r[0] for r in conn.execute("SELECT ZMESSAGEDATE FROM ZWAMESSAGE ORDER BY ZSORT")]
    assert dates == sorted(dates)
    bob = conn.execute("SELECT ZGROUPMEMBER FROM ZWAMESSAGE WHERE ZSTANZAID='K111'").fetchone()[0]
    assert bob == 1
    assert conn.execute("SELECT COUNT(*) FROM ZWAGROUPMEMBER WHERE ZMEMBERJID LIKE '%61400000003%'").fetchone()[0] == 0
    bob_session = conn.execute("SELECT ZCONTACTJID, ZCONTACTIDENTIFIER FROM ZWACHATSESSION WHERE Z_PK=3").fetchone()
    assert bob_session == (BOB_LID, BOB_PN)
    caption = conn.execute("SELECT i.ZTITLE, i.ZVCARDSTRING, m.ZTEXT FROM ZWAMESSAGE m JOIN ZWAMEDIAITEM i "
                           "ON i.Z_PK = m.ZMEDIAITEM WHERE m.ZSTANZAID='K102'").fetchone()
    assert caption == ("look at this", "image/jpeg", None)
    maxima = dict(conn.execute("SELECT Z_NAME, Z_MAX FROM Z_PRIMARYKEY"))
    assert maxima["WAMessage"] == conn.execute("SELECT MAX(Z_PK) FROM ZWAMESSAGE").fetchone()[0]
    conn.close()
    again = chatstorage.Writer(database, msgstore.parse(tmp_path / "msgstore.db").lids)
    report = again.import_archive(msgstore.parse(tmp_path / "msgstore.db"), tmp_path / "Media")
    again.close()
    assert report.messages_written == 0


@pytest.mark.parametrize("password", [None, PASSWORD])
def test_backup_put_and_read(tmp_path: Path, password: str | None) -> None:
    make_chatstorage(tmp_path / CHATSTORAGE)
    folder = make_backup(tmp_path / "backup" / UDID, tmp_path / CHATSTORAGE, password)
    media = tmp_path / "photo.jpg"
    media.write_bytes(os.urandom(5000))
    replacement = tmp_path / "replacement.sqlite"
    replacement.write_bytes(b"SQLite format 3\x00" + os.urandom(3000))
    relative = f"Message/Media/{BOB_LID}/A/B/PHOTO.jpg"
    with Backup(folder, password) as target:
        copy = tmp_path / "copy.sqlite"
        assert target.read(CHATSTORAGE, copy)
        assert copy.read_bytes() == (tmp_path / CHATSTORAGE).read_bytes()
        target.put(relative, media)
        target.put(CHATSTORAGE, replacement)
        assert target.check() == []
    with Backup(folder, password) as reopened:
        for depth in ("Message/Media", f"Message/Media/{BOB_LID}", f"Message/Media/{BOB_LID}/A/B"):
            entry = reopened.get(depth)
            assert entry.flags == DIRECTORY and mbfile(entry.blob)["RelativePath"] == depth
        entry = reopened.get(relative)
        info = mbfile(entry.blob)
        assert info["RelativePath"] == relative and info["Size"] == 5000
        payload = reopened.payload_path(entry.file_id).read_bytes()
        assert ("Digest" in info) == bool(password)
        if password:
            assert info["Digest"] == hashlib.sha1(payload).digest()
        out = tmp_path / "out.jpg"
        assert reopened.read(relative, out) and out.read_bytes() == media.read_bytes()
    reference = ReferenceBackup.from_path(folder, password or "")
    assert reference.get_entry_by_domain_and_path(WA_DOMAIN, relative).read_bytes() == media.read_bytes()
    assert reference.get_entry_by_domain_and_path(WA_DOMAIN, CHATSTORAGE).read_bytes() == replacement.read_bytes()


def test_wrong_password(tmp_path: Path) -> None:
    make_chatstorage(tmp_path / CHATSTORAGE)
    folder = make_backup(tmp_path / UDID, tmp_path / CHATSTORAGE, PASSWORD)
    with pytest.raises(BackupError):
        Backup(folder, "nope")
    with pytest.raises(BackupError):
        Backup(folder, None)


def test_prune(tmp_path: Path) -> None:
    make_chatstorage(tmp_path / CHATSTORAGE)
    folder = make_backup(tmp_path / UDID, tmp_path / CHATSTORAGE, PASSWORD)
    other = file_id("HomeDomain", "Library/Preferences/com.apple.example.plist")
    with Backup(folder, PASSWORD) as target:
        target.prune()
    assert not (folder / other[:2] / other).exists()
    with Backup(folder, PASSWORD) as reopened:
        domains = {r[0] for r in reopened.conn.execute("SELECT DISTINCT domain FROM Files")}
        assert domains == {WA_DOMAIN}
        assert reopened.get(CHATSTORAGE) and reopened.get("") and reopened.check() == []


def test_build_command(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    work = tmp_path / "work"
    (work / "android").mkdir(parents=True)
    make_msgstore(work / "android" / "msgstore.db")
    make_media(work / "android" / "Media")
    make_chatstorage(tmp_path / CHATSTORAGE)
    make_backup(work / "ios" / "pristine" / UDID, tmp_path / CHATSTORAGE, PASSWORD)
    before = (work / "ios" / "pristine" / UDID / "Manifest.db").read_bytes()
    monkeypatch.setenv("WAMOVE_BACKUP_PASSWORD", PASSWORD)
    assert main(["--work", str(work), "build"]) == 0
    assert (work / "ios" / "pristine" / UDID / "Manifest.db").read_bytes() == before
    reference = ReferenceBackup.from_path(work / "ios" / "patched" / UDID, PASSWORD)
    database = tmp_path / "result.sqlite"
    database.write_bytes(reference.get_entry_by_domain_and_path(WA_DOMAIN, CHATSTORAGE).read_bytes())
    assert chatstorage.verify(database) == []
    conn = sqlite3.connect(database)
    assert conn.execute("SELECT COUNT(*) FROM ZWAMESSAGE").fetchone()[0] == 12
    path = conn.execute("SELECT ZMEDIALOCALPATH FROM ZWAMEDIAITEM WHERE ZMEDIALOCALPATH IS NOT NULL").fetchone()[0]
    conn.close()
    assert reference.get_entry_by_domain_and_path(WA_DOMAIN, "Message/" + path).read_bytes()
    assert reference.get_entry_by_domain_and_path(WA_DOMAIN, CHATSTORAGE + "-wal").read_bytes() == b""
    assert reference.get_entry_by_domain_and_path(WA_DOMAIN, CHATSTORAGE + "-shm").read_bytes() == b""
