from __future__ import annotations

import hashlib
import os
import plistlib
import sqlite3
import struct
from pathlib import Path

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.keywrap import aes_key_wrap

from wamove.ios.backup import CHATSTORAGE, DIRECTORY, FILE, WA_DOMAIN, file_id

ME = "61400000001@s.whatsapp.net"
ALICE = "61400000002@s.whatsapp.net"
BOB_LID = "123456789012345@lid"
BOB_PN = "61400000003@s.whatsapp.net"
GROUP = "61400000001-1700000000@g.us"
PASSWORD = "correct horse"
UDID = "00008110-000A1B2C3D4E5F60"


def make_msgstore(path: Path) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE jid (_id INTEGER PRIMARY KEY, user TEXT, server TEXT, raw_string TEXT UNIQUE);
        CREATE TABLE chat (_id INTEGER PRIMARY KEY, jid_row_id INTEGER UNIQUE, hidden INTEGER, subject TEXT,
                           created_timestamp INTEGER, archived INTEGER);
        CREATE TABLE message (_id INTEGER PRIMARY KEY, chat_row_id INTEGER, from_me INTEGER, key_id TEXT,
                              sender_jid_row_id INTEGER, status INTEGER, timestamp INTEGER, message_type INTEGER,
                              text_data TEXT, starred INTEGER);
        CREATE TABLE message_media (message_row_id INTEGER PRIMARY KEY, chat_row_id INTEGER, file_path TEXT,
                                    file_size INTEGER, mime_type TEXT, media_name TEXT, media_duration INTEGER,
                                    width INTEGER, height INTEGER);
        CREATE TABLE message_location (message_row_id INTEGER PRIMARY KEY, latitude REAL, longitude REAL,
                                       place_name TEXT);
        CREATE TABLE message_vcard (_id INTEGER PRIMARY KEY, message_row_id INTEGER, vcard TEXT);
        CREATE TABLE group_participant_user (_id INTEGER PRIMARY KEY, group_jid_row_id INTEGER,
                                             user_jid_row_id INTEGER, rank INTEGER);
        CREATE TABLE jid_map (lid_row_id INTEGER PRIMARY KEY, jid_row_id INTEGER);
        """
    )
    for row_id, raw in [(1, ME), (2, ALICE), (3, BOB_LID), (4, BOB_PN), (5, GROUP), (6, "status@broadcast")]:
        user, server = raw.split("@")
        conn.execute("INSERT INTO jid VALUES (?,?,?,?)", (row_id, user, server, raw))
    conn.execute("INSERT INTO jid_map VALUES (3, 4)")
    conn.executemany("INSERT INTO chat VALUES (?,?,0,?,?,0)", [
        (10, 2, None, None), (11, 5, "Family", 1_700_000_000_000), (12, 6, None, None), (13, 3, None, None)])
    conn.executemany("INSERT INTO group_participant_user VALUES (?,5,?,?)", [(1, 1, 1), (2, 2, 0), (3, 3, 0)])
    t0 = 1_726_000_000_000
    rows = [
        (100, 10, 0, "K100", 2, t0 + 1000, 0, "hi from alice"),
        (101, 10, 1, "K101", None, t0 + 2000, 0, "hello!"),
        (102, 10, 0, "K102", 2, t0 + 3000, 1, "look at this"),
        (103, 10, 1, "K103", None, t0 + 4000, 2, None),
        (104, 10, 0, "K104", 2, t0 + 5000, 5, None),
        (105, 10, 0, "K105", 2, t0 + 6000, 4, "Bob"),
        (106, 10, 0, "K106", 2, t0 + 7000, 7, None),
        (107, 10, 0, "K107", 2, t0 + 8000, 15, None),
        (108, 10, 0, "K108", 2, t0 + 9000, 20, None),
        (109, 10, 0, "K109", 2, t0 + 9500, 9, None),
        (110, 11, 0, "K110", 2, t0 + 10000, 0, "group msg from alice"),
        (111, 11, 0, "K111", 3, t0 + 11000, 0, "group msg from bob"),
        (112, 11, 1, "K112", None, t0 + 12000, 3, None),
        (113, 12, 0, "K113", 2, t0 + 13000, 1, None),
        (114, 13, 0, "K114", 3, t0 + 14000, 0, "hi, bob here"),
        (115, 13, 1, "K115", None, t0 + 15000, 90, None),
        (116, 13, 0, "K116", 3, t0 + 16000, 99, None),
        (117, 13, 1, "K117", None, t0 + 17000, 49, "sent with a newer message type"),
        (118, 13, 0, "K118", 3, t0 + 18000, 0, None),
    ]
    conn.executemany("INSERT INTO message VALUES (?,?,?,?,?,0,?,?,?,0)", rows)
    conn.executemany("INSERT INTO message_media VALUES (?,?,?,?,?,?,?,?,?)", [
        (102, 10, "Media/WhatsApp Images/IMG-001.jpg", 12, "image/jpeg", None, None, 640, 480),
        (103, 10, "Media/WhatsApp Voice Notes/202437/PTT-001.opus", 9, "audio/ogg; codecs=opus", None, 7, None, None),
        (108, 10, "Media/WhatsApp Stickers/STK-001.webp", 8, "image/webp", None, None, 512, 512),
        (109, 10, "Media/WhatsApp Documents/report.pdf", 8, "application/pdf", "report.pdf", None, None, None),
        (112, 11, "Media/WhatsApp Video/Sent/VID-001.mp4", 55555, "video/mp4", None, 12, 1280, 720),
    ])
    conn.execute("INSERT INTO message_location VALUES (104, -37.81, 144.96, 'Melbourne')")
    conn.execute("INSERT INTO message_vcard VALUES (1, 105, 'BEGIN:VCARD\nFN:Bob Example\nEND:VCARD')")
    conn.commit()
    conn.close()


def make_media(root: Path) -> None:
    for relative, data in {
        "WhatsApp Images/IMG-001.jpg": b"\xff\xd8jpegdata!!",
        "WhatsApp Voice Notes/202437/PTT-001.opus": b"OggS-opus",
        "WhatsApp Stickers/STK-001.webp": b"RIFFwebp",
        "WhatsApp Documents/report.pdf": b"%PDF-1.4" * 40,
    }.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


ENTITIES = [(1, "WAChatProperties"), (2, "WAChatSession"), (3, "WAGroupInfo"), (4, "WAGroupMember"),
            (5, "WAMediaItem"), (6, "WAMessage")]


def make_chatstorage(path: Path) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
        CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZARCHIVED INTEGER,
            ZCONTACTABID INTEGER, ZFLAGS INTEGER, ZHIDDEN INTEGER, ZMESSAGECOUNTER INTEGER, ZREMOVED INTEGER,
            ZSESSIONTYPE INTEGER, ZSPOTLIGHTSTATUS INTEGER, ZUNREADCOUNT INTEGER, ZGROUPINFO INTEGER,
            ZLASTMESSAGE INTEGER, ZPROPERTIES INTEGER, ZLASTMESSAGEDATE TIMESTAMP, ZCONTACTIDENTIFIER VARCHAR,
            ZCONTACTJID VARCHAR, ZLASTMESSAGETEXT VARCHAR, ZPARTNERNAME VARCHAR);
        CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
            ZCHILDMESSAGESDELIVEREDCOUNT INTEGER, ZDATAITEMVERSION INTEGER, ZDOCID INTEGER, ZFLAGS INTEGER,
            ZISFROMME INTEGER, ZMESSAGEERRORSTATUS INTEGER, ZMESSAGESTATUS INTEGER, ZMESSAGETYPE INTEGER,
            ZSORT INTEGER, ZSPOTLIGHTSTATUS INTEGER, ZSTARRED INTEGER, ZCHATSESSION INTEGER, ZGROUPMEMBER INTEGER,
            ZLASTSESSION INTEGER, ZMEDIAITEM INTEGER, ZMESSAGEDATE TIMESTAMP, ZSENTDATE TIMESTAMP, ZFROMJID VARCHAR,
            ZMEDIASECTIONID VARCHAR, ZPUSHNAME VARCHAR, ZSTANZAID VARCHAR, ZTEXT VARCHAR, ZTOJID VARCHAR);
        CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCLOUDSTATUS INTEGER,
            ZFILESIZE INTEGER, ZMEDIAORIGIN INTEGER, ZMOVIEDURATION INTEGER, ZMESSAGE INTEGER, ZASPECTRATIO FLOAT,
            ZLATITUDE FLOAT, ZLONGITUDE FLOAT, ZMEDIALOCALPATH VARCHAR, ZTITLE VARCHAR, ZVCARDNAME VARCHAR,
            ZVCARDSTRING VARCHAR, ZXMPPTHUMBPATH VARCHAR);
        CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZISACTIVE INTEGER,
            ZISADMIN INTEGER, ZCHATSESSION INTEGER, ZCONTACTNAME VARCHAR, ZMEMBERJID VARCHAR);
        CREATE TABLE ZWAGROUPINFO (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZGENERATION INTEGER,
            ZCHATSESSION INTEGER, ZCREATIONDATE TIMESTAMP);
        CREATE TABLE ZWACHATPROPERTIES (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCHATSESSION INTEGER);
        """
    )
    maxima = {"WAChatSession": 2, "WAMessage": 1, "WAGroupMember": 1}
    for ent, name in ENTITIES:
        conn.execute("INSERT INTO Z_PRIMARYKEY VALUES (?,?,0,?)", (ent, name, maxima.get(name, 0)))
    conn.execute("INSERT INTO ZWACHATSESSION (Z_PK, Z_ENT, Z_OPT, ZSESSIONTYPE, ZMESSAGECOUNTER, ZCONTACTJID, "
                 "ZPARTNERNAME, ZFLAGS, ZLASTMESSAGEDATE) VALUES (1, 2, 1, 0, 1, ?, 'Alice', 272, 748000000.0)",
                 (ALICE,))
    conn.execute("INSERT INTO ZWACHATSESSION (Z_PK, Z_ENT, Z_OPT, ZSESSIONTYPE, ZMESSAGECOUNTER, ZCONTACTJID, "
                 "ZPARTNERNAME, ZFLAGS) VALUES (2, 2, 1, 1, 0, ?, 'Family', 256)", (GROUP,))
    conn.execute("INSERT INTO ZWAGROUPMEMBER VALUES (1, 4, 1, 1, 0, 2, 'Bob', ?)", (BOB_LID,))
    conn.execute("INSERT INTO ZWAMESSAGE (Z_PK, Z_ENT, Z_OPT, ZISFROMME, ZMESSAGETYPE, ZSORT, ZCHATSESSION, "
                 "ZMESSAGEDATE, ZTOJID, ZSTANZAID, ZTEXT, ZFLAGS, ZMESSAGESTATUS) "
                 "VALUES (1, 6, 1, 1, 0, 1, 1, 748000000.0, ?, 'K101', 'hello!', 16777280, 8)", (ALICE,))
    conn.commit()
    conn.close()


def mbfile_blob(relative_path: str, size: int, mode: int, inode: int, protection: int,
                key: bytes | None = None, digest: bytes | None = None) -> bytes:
    root: dict = {"Birth": 1_700_000_000, "Flags": 0, "GroupID": 501, "InodeNumber": inode,
                  "LastModified": 1_700_000_000, "LastStatusChange": 1_700_000_000, "Mode": mode,
                  "ProtectionClass": protection, "RelativePath": plistlib.UID(2), "Size": size, "UserID": 501}
    objects: list = ["$null", root, relative_path]
    if digest is not None:
        objects.append(digest)
        root["Digest"] = plistlib.UID(len(objects) - 1)
    if key is not None:
        objects.append({"NS.data": key, "$class": plistlib.UID(len(objects) + 1)})
        objects.append({"$classname": "NSMutableData", "$classes": ["NSMutableData", "NSData", "NSObject"]})
        root["EncryptionKey"] = plistlib.UID(len(objects) - 2)
    objects.append({"$classname": "MBFile", "$classes": ["MBFile", "NSObject"]})
    root["$class"] = plistlib.UID(len(objects) - 1)
    return plistlib.dumps({"$version": 100000, "$archiver": "NSKeyedArchiver", "$top": {"root": plistlib.UID(1)},
                           "$objects": objects}, fmt=plistlib.FMT_BINARY)


def _tlv(tag: bytes, value: bytes | int) -> bytes:
    data = struct.pack(">I", value) if isinstance(value, int) else value
    return tag + struct.pack(">I", len(data)) + data


def _cbc(key: bytes, data: bytes) -> bytes:
    encryptor = Cipher(algorithms.AES(key), modes.CBC(b"\x00" * 16)).encryptor()
    return encryptor.update(data) + encryptor.finalize()


def _pad(data: bytes) -> bytes:
    padder = padding.PKCS7(128).padder()
    return padder.update(data) + padder.finalize()


def make_backup(folder: Path, chatstorage: Path, password: str | None = None) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    class_keys = {cls: os.urandom(32) for cls in range(1, 12)} if password else {}
    manifest: dict = {"IsEncrypted": bool(password), "Version": "10.0", "Lockdown": {"ProductVersion": "26.0"},
                      "Applications": {}}
    if password:
        salt, dpsl = os.urandom(20), os.urandom(20)
        inner = hashlib.pbkdf2_hmac("sha256", password.encode(), dpsl, 1, 32)
        derived = hashlib.pbkdf2_hmac("sha1", inner, salt, 1, 32)
        keybag = b"".join([_tlv(b"VERS", 4), _tlv(b"TYPE", 1), _tlv(b"UUID", os.urandom(16)),
                           _tlv(b"HMCK", os.urandom(40)), _tlv(b"WRAP", 0), _tlv(b"SALT", salt), _tlv(b"ITER", 1),
                           _tlv(b"DPWT", 1), _tlv(b"DPIC", 1), _tlv(b"DPSL", dpsl)])
        for cls, key in class_keys.items():
            keybag += b"".join([_tlv(b"UUID", os.urandom(16)), _tlv(b"CLAS", cls), _tlv(b"WRAP", 3),
                                _tlv(b"KTYP", 0), _tlv(b"WPKY", aes_key_wrap(derived, key))])
        manifest_key = os.urandom(32)
        manifest["BackupKeyBag"] = keybag
        manifest["ManifestKey"] = struct.pack("<I", 4) + aes_key_wrap(class_keys[4], manifest_key)
    (folder / "Manifest.plist").write_bytes(plistlib.dumps(manifest))
    (folder / "Info.plist").write_bytes(plistlib.dumps({"Applications": {}}))
    (folder / "Status.plist").write_bytes(plistlib.dumps({"BackupState": "new", "IsFullBackup": True}))

    database = folder / "Manifest.plain.db"
    conn = sqlite3.connect(database)
    conn.execute("CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, "
                 "file BLOB)")
    conn.execute("CREATE TABLE Properties (key TEXT PRIMARY KEY, value BLOB)")
    inode = 500

    def add(domain: str, relative_path: str, content: bytes | None) -> None:
        nonlocal inode
        inode += 1
        fid = file_id(domain, relative_path)
        if content is None:
            blob = mbfile_blob(relative_path, 0, 0o40755, inode, 0)
            conn.execute("INSERT INTO Files VALUES (?,?,?,?,?)", (fid, domain, relative_path, DIRECTORY, blob))
            return
        stored, key = content, None
        if password:
            file_key = os.urandom(32)
            key = struct.pack("<I", 3) + aes_key_wrap(class_keys[3], file_key)
            stored = _cbc(file_key, _pad(content))
        blob = mbfile_blob(relative_path, len(content), 0o100644, inode, 3, key,
                           hashlib.sha1(stored).digest() if password else None)
        conn.execute("INSERT INTO Files VALUES (?,?,?,?,?)", (fid, domain, relative_path, FILE, blob))
        (folder / fid[:2]).mkdir(exist_ok=True)
        (folder / fid[:2] / fid).write_bytes(stored)

    add(WA_DOMAIN, "", None)
    add(WA_DOMAIN, "Message", None)
    add(WA_DOMAIN, CHATSTORAGE, chatstorage.read_bytes())
    add(WA_DOMAIN, CHATSTORAGE + "-wal", b"")
    add("HomeDomain", "", None)
    add("HomeDomain", "Library/Preferences/com.apple.example.plist", b"unrelated")
    conn.commit()
    conn.close()
    plain = database.read_bytes()
    database.unlink()
    (folder / "Manifest.db").write_bytes(_cbc(manifest_key, plain) if password else plain)
    return folder
