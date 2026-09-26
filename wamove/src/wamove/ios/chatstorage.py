from __future__ import annotations

import base64
import datetime
import functools
import hashlib
import os
import re
import sqlite3
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from ..model import MEDIA_KINDS, Archive, Chat, Kind, Message
from . import thumbs

COCOA_EPOCH = 978307200
IOS_TYPE = {
    Kind.TEXT: 0,
    Kind.IMAGE: 1,
    Kind.VIDEO: 2,
    Kind.AUDIO: 3,
    Kind.VOICE: 3,
    Kind.CONTACT: 4,
    Kind.LOCATION: 5,
    Kind.SYSTEM: 6,
    Kind.DOCUMENT: 8,
    Kind.GIF: 11,
    Kind.REVOKED: 14,
    Kind.STICKER: 15,
    Kind.UNKNOWN: 0,
}
INDIVIDUAL = 0
GROUP = 1
MEDIA_PREFIX = "Message/"
SYSTEM_TYPES = (6, 10)
VISUAL_KINDS = frozenset({Kind.IMAGE, Kind.VIDEO, Kind.GIF, Kind.STICKER})


class ChatStorageError(Exception):
    pass


@dataclass
class MediaFile:
    source: str
    relative_path: str


@dataclass
class Report:
    sessions_created: int = 0
    sessions_reused: int = 0
    messages_written: int = 0
    messages_skipped: int = 0
    media_linked: int = 0
    media_missing: int = 0
    thumbnails: int = 0
    media_files: list[MediaFile] = field(default_factory=list)


def cocoa(ms: int) -> float:
    return ms / 1000 - COCOA_EPOCH


def _sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return base64.b64encode(digest.digest()).decode()


def _is_blob(value: object) -> bool:
    if not isinstance(value, str) or len(value) < 8 or not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", value):
        return False
    try:
        raw = base64.b64decode(value, validate=True)
    except ValueError:
        return False
    return len(raw) >= 4 and 0x08 <= raw[0] < 0x80


def _is_mime(value: object) -> bool:
    return isinstance(value, str) and bool(re.fullmatch(r"[a-z]+/[\w.+-]+(;.*)?", value))


def _vcard_name(vcard: str) -> str | None:
    return next((line.split(":", 1)[-1].strip() for line in vcard.splitlines() if line.startswith("FN")), None)


def _section(ms: int) -> str:
    d = datetime.datetime.fromtimestamp(ms / 1000, tz=datetime.timezone.utc)
    return f"{d.year}-{d.month:02d}"


@functools.lru_cache(maxsize=4)
def _media_index(root: str) -> dict[str, str]:
    index: dict[str, str] = {}
    for directory, _, files in os.walk(root):
        for name in files:
            index.setdefault(name, os.path.join(directory, name))
    return index


def _locate(android_path: str | None, media_root: str) -> str | None:
    if not android_path:
        return None
    relative = android_path.lstrip("/")
    relative = relative[len("Media/"):] if relative.startswith("Media/") else relative
    candidate = os.path.join(media_root, relative)
    if os.path.isfile(candidate):
        return candidate
    return _media_index(media_root).get(os.path.basename(relative))


class Writer:
    def __init__(self, path: Path, lids: dict[str, str] | None = None):
        if not path.is_file():
            raise ChatStorageError(f"{path} not found")
        self.conn = sqlite3.connect(path)
        self.conn.row_factory = sqlite3.Row
        self.lids = lids or {}
        self.thumbnails: Path | None = None
        self.columns = {
            name: [r[1] for r in self.conn.execute(f'PRAGMA table_info("{name}")')]
            for (name,) in self.conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        for required in ("Z_PRIMARYKEY", "ZWACHATSESSION", "ZWAMESSAGE"):
            if required not in self.columns:
                raise ChatStorageError(f"{path} is not WhatsApp's ChatStorage.sqlite (no {required})")
        self.entities = {
            r["Z_NAME"]: {"ent": r["Z_ENT"], "max": r["Z_MAX"] or 0}
            for r in self.conn.execute("SELECT Z_ENT, Z_NAME, Z_MAX FROM Z_PRIMARYKEY")
        }
        self.conv = self._learn()

    def _mode(self, sql: str, default: object = None) -> object:
        try:
            row = self.conn.execute(sql + " GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 1").fetchone()
        except sqlite3.DatabaseError:
            return default
        return row[0] if row and row[0] is not None else default

    def _sample(self, sql: str) -> object:
        try:
            row = self.conn.execute(sql + " LIMIT 1").fetchone()
        except sqlite3.DatabaseError:
            return None
        return row[0] if row else None

    def _learn(self) -> dict:
        conv = {
            "msg_flags_in": self._mode("SELECT ZFLAGS FROM ZWAMESSAGE WHERE ZISFROMME=0 AND ZMESSAGETYPE=0", 16777216),
            "msg_flags_out": self._mode("SELECT ZFLAGS FROM ZWAMESSAGE WHERE ZISFROMME=1", 16777280),
            "msg_dataver": self._mode("SELECT ZDATAITEMVERSION FROM ZWAMESSAGE", 3),
            "msg_spot": self._mode("SELECT ZSPOTLIGHTSTATUS FROM ZWAMESSAGE", -32768),
            "msg_status_in": self._mode(
                "SELECT ZMESSAGESTATUS FROM ZWAMESSAGE WHERE ZISFROMME=0 AND ZMESSAGETYPE=0", 0),
            "msg_status_out": self._mode("SELECT ZMESSAGESTATUS FROM ZWAMESSAGE WHERE ZISFROMME=1", 8),
            "sess_flags_1to1": self._mode("SELECT ZFLAGS FROM ZWACHATSESSION WHERE ZSESSIONTYPE=0", 272),
            "sess_flags_group": self._mode("SELECT ZFLAGS FROM ZWACHATSESSION WHERE ZSESSIONTYPE=1", 256),
            "sess_spot_1to1": self._mode("SELECT ZSPOTLIGHTSTATUS FROM ZWACHATSESSION WHERE ZSESSIONTYPE=0", -5),
            "sess_spot_group": self._mode("SELECT ZSPOTLIGHTSTATUS FROM ZWACHATSESSION WHERE ZSESSIONTYPE=1", 1),
            "media_origin": self._mode("SELECT ZMEDIAORIGIN FROM ZWAMEDIAITEM WHERE ZMEDIALOCALPATH IS NOT NULL", 0),
            "media_cloud": self._mode("SELECT ZCLOUDSTATUS FROM ZWAMEDIAITEM WHERE ZMEDIALOCALPATH IS NOT NULL", 0),
            "event_in": self._mode("SELECT ZGROUPEVENTTYPE FROM ZWAMESSAGE WHERE ZISFROMME=0 AND ZMESSAGETYPE NOT IN "
                                   f"{SYSTEM_TYPES}", 0),
            "event_out": self._mode("SELECT ZGROUPEVENTTYPE FROM ZWAMESSAGE WHERE ZISFROMME=1 AND ZMESSAGETYPE NOT IN "
                                    f"{SYSTEM_TYPES}", 0),
        }
        conv["flags_by_type"] = {}
        for from_me, kind, flags, _ in self.conn.execute(
                "SELECT ZISFROMME, ZMESSAGETYPE, ZFLAGS, COUNT(*) FROM ZWAMESSAGE WHERE ZFLAGS IS NOT NULL "
                "GROUP BY 1, 2, 3 ORDER BY 4"):
            conv["flags_by_type"][f"{from_me}:{kind}"] = flags
        conv["pushname_is_blob"] = _is_blob(self._sample(
            "SELECT ZPUSHNAME FROM ZWAMESSAGE WHERE ZPUSHNAME IS NOT NULL AND ZPUSHNAME<>''"))
        conv["lasttext_is_blob"] = _is_blob(self._sample(
            "SELECT ZLASTMESSAGETEXT FROM ZWACHATSESSION WHERE ZLASTMESSAGETEXT IS NOT NULL"))
        member = self._sample("SELECT ZMEMBERJID FROM ZWAGROUPMEMBER WHERE ZMEMBERJID IS NOT NULL ORDER BY Z_PK DESC")
        conv["member_lid"] = isinstance(member, str) and member.endswith("@lid")
        sender = self._sample(
            "SELECT m.ZFROMJID FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION "
            "WHERE m.ZISFROMME=0 AND s.ZSESSIONTYPE=0 AND m.ZFROMJID IS NOT NULL ORDER BY m.Z_PK DESC")
        conv["from_lid"] = isinstance(sender, str) and sender.endswith("@lid")
        mime = self._sample(
            "SELECT ZVCARDSTRING FROM ZWAMEDIAITEM WHERE ZMEDIALOCALPATH IS NOT NULL AND ZVCARDSTRING IS NOT NULL")
        conv["mime_in_vcard"] = mime is None or _is_mime(mime)
        conv["use_properties"] = "ZWACHATPROPERTIES" in self.columns and bool(self._sample(
            "SELECT COUNT(*) FROM ZWACHATSESSION WHERE ZPROPERTIES IS NOT NULL"))
        conv["required"] = {t: self._required(t) for t in ("ZWAMEDIAITEM", "ZWAMESSAGE", "ZWACHATSESSION",
                                                            "ZWAGROUPMEMBER", "ZWAGROUPINFO") if t in self.columns}
        return conv

    def _required(self, table: str) -> dict[str, int | float]:
        rows = self.conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        result: dict[str, int | float] = {}
        for _, name, kind, *_ in self.conn.execute(f'PRAGMA table_info("{table}")'):
            kind = (kind or "").upper()
            if name.startswith("Z_") or "TIMESTAMP" in kind or "DATE" in name:
                continue
            if not any(k in kind for k in ("INT", "FLOAT", "REAL", "DOUBLE")):
                continue
            if rows and self.conn.execute(f"SELECT COUNT(*) FROM {table} WHERE {name} IS NULL").fetchone()[0]:
                continue
            result[name] = 0.0 if any(k in kind for k in ("FLOAT", "REAL", "DOUBLE")) else 0
        return result

    def _next_pk(self, entity: str) -> int:
        if entity not in self.entities:
            raise ChatStorageError(f"entity {entity} is missing from Z_PRIMARYKEY")
        self.entities[entity]["max"] += 1
        return self.entities[entity]["max"]

    def insert(self, table: str, entity: str, values: dict) -> int:
        pk = self._next_pk(entity)
        row = {"Z_PK": pk, "Z_ENT": self.entities[entity]["ent"], "Z_OPT": 1}
        row.update({k: v for k, v in values.items() if k in self.columns[table]})
        for column, default in self.conv["required"].get(table, {}).items():
            if row.get(column) is None:
                row[column] = default
        self.conn.execute(
            f"INSERT INTO {table} ({', '.join(row)}) VALUES ({', '.join('?' for _ in row)})", list(row.values()))
        return pk

    def update(self, table: str, pk: int, values: dict) -> None:
        values = {k: v for k, v in values.items() if k in self.columns[table]}
        if values:
            self.conn.execute(
                f"UPDATE {table} SET {', '.join(f'{k}=?' for k in values)} WHERE Z_PK=?", [*values.values(), pk])

    def find_session(self, *jids: str | None) -> sqlite3.Row | None:
        keys = [j for j in jids if j]
        if not keys:
            return None
        marks = ",".join("?" for _ in keys)
        return self.conn.execute(
            f"SELECT * FROM ZWACHATSESSION WHERE ZCONTACTJID IN ({marks}) OR ZCONTACTIDENTIFIER IN ({marks}) "
            "ORDER BY ZSESSIONTYPE LIMIT 1", keys + keys).fetchone()

    def import_archive(self, archive: Archive, media_root: Path | None, thumbnails: Path | None = None) -> Report:
        report = Report()
        self.thumbnails = thumbnails
        touched: set[int] = set()
        for chat in archive.chats:
            session = self._import_chat(chat, archive, report, str(media_root) if media_root else None)
            if session is not None:
                touched.add(session)
        for session in touched:
            rows = self.conn.execute(
                "SELECT Z_PK FROM ZWAMESSAGE WHERE ZCHATSESSION=? ORDER BY ZMESSAGEDATE, Z_PK", (session,)).fetchall()
            self.conn.executemany("UPDATE ZWAMESSAGE SET ZSORT=? WHERE Z_PK=?",
                                  [(i, r[0]) for i, r in enumerate(rows, 1)])
        for name, entity in self.entities.items():
            self.conn.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=? WHERE Z_NAME=?", (entity["max"], name))
        self.conn.commit()
        return report

    def close(self) -> None:
        self.conn.commit()
        self.conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        self.conn.execute("PRAGMA journal_mode=DELETE")
        self.conn.close()

    def _session(self, chat: Chat, report: Report) -> tuple[int, sqlite3.Row | None]:
        session = self.find_session(chat.jid, chat.lid)
        if session:
            report.sessions_reused += 1
            return session["Z_PK"], session
        conv = self.conv
        pk = self.insert("ZWACHATSESSION", "WAChatSession", {
            "ZCONTACTJID": chat.jid if chat.is_group else (chat.lid or chat.jid),
            "ZCONTACTIDENTIFIER": None if chat.is_group or chat.jid.endswith("@lid") else chat.jid,
            "ZPARTNERNAME": chat.name or chat.phone or chat.jid.split("@")[0],
            "ZSESSIONTYPE": GROUP if chat.is_group else INDIVIDUAL,
            "ZMESSAGECOUNTER": 0,
            "ZUNREADCOUNT": 0,
            "ZARCHIVED": int(chat.archived),
            "ZHIDDEN": 0,
            "ZREMOVED": 0,
            "ZCONTACTABID": 0,
            "ZIDENTITYVERIFICATIONEPOCH": 0,
            "ZIDENTITYVERIFICATIONSTATE": 0,
            "ZFLAGS": conv["sess_flags_group"] if chat.is_group else conv["sess_flags_1to1"],
            "ZSPOTLIGHTSTATUS": conv["sess_spot_group"] if chat.is_group else conv["sess_spot_1to1"],
            "ZLASTMESSAGEDATE": cocoa(chat.messages[-1].timestamp_ms),
        })
        report.sessions_created += 1
        if chat.is_group and "ZWAGROUPINFO" in self.columns and "WAGroupInfo" in self.entities:
            info = self.insert("ZWAGROUPINFO", "WAGroupInfo", {
                "ZCHATSESSION": pk,
                "ZCREATIONDATE": cocoa(chat.created_ms) if chat.created_ms else None,
                "ZGENERATION": 0,
            })
            self.update("ZWACHATSESSION", pk, {"ZGROUPINFO": info})
        if conv["use_properties"] and "WAChatProperties" in self.entities:
            properties = self.insert("ZWACHATPROPERTIES", "WAChatProperties", {"ZCHATSESSION": pk})
            self.update("ZWACHATSESSION", pk, {"ZPROPERTIES": properties})
        return pk, None

    def _members(self, session: int) -> dict[str, int]:
        if "ZWAGROUPMEMBER" not in self.columns:
            return {}
        rows = self.conn.execute("SELECT Z_PK, ZMEMBERJID FROM ZWAGROUPMEMBER WHERE ZCHATSESSION=?", (session,))
        return {r["ZMEMBERJID"]: r["Z_PK"] for r in rows if r["ZMEMBERJID"]}

    def _member(self, session: int, members: dict[str, int], jid: str, name: str | None, admin: bool,
                active: bool) -> int:
        lid = self.lids.get(jid)
        for key in (jid, lid):
            if key and key in members:
                members[jid] = members[key]
                return members[key]
        stored = lid if self.conv["member_lid"] and lid else jid
        pk = self.insert("ZWAGROUPMEMBER", "WAGroupMember", {
            "ZCHATSESSION": session,
            "ZMEMBERJID": stored,
            "ZCONTACTNAME": name or jid.split("@")[0],
            "ZISACTIVE": int(active),
            "ZISADMIN": int(admin),
        })
        members[stored] = members[jid] = pk
        return pk

    def _import_chat(self, chat: Chat, archive: Archive, report: Report, media_root: str | None) -> int | None:
        session, existing = self._session(chat, report)
        media_dir = chat.jid if chat.is_group else (chat.lid or chat.jid)
        members = self._members(session) if chat.is_group else {}
        for participant in chat.participants if chat.is_group else ():
            self._member(session, members, participant.jid, participant.name or archive.names.get(participant.jid),
                         participant.is_admin, True)
        seen = {r[0] for r in self.conn.execute(
            "SELECT ZSTANZAID FROM ZWAMESSAGE WHERE ZCHATSESSION=? AND ZSTANZAID IS NOT NULL", (session,))}
        last_pk = last_date = last_text = None
        written = 0
        for message in chat.messages:
            if message.key_id in seen:
                report.messages_skipped += 1
                continue
            seen.add(message.key_id)
            member = None
            if chat.is_group and not message.from_me and message.sender_jid:
                member = self._member(session, members, message.sender_jid,
                                      archive.names.get(message.sender_jid), False, False)
            last_pk = self._message(chat, session, message, member, archive, report, media_root, media_dir)
            last_date = cocoa(message.timestamp_ms)
            last_text = message.text if message.kind is Kind.TEXT else last_text
            written += 1
            report.messages_written += 1
        if last_pk is None:
            return None
        values: dict = {"ZMESSAGECOUNTER": ((existing["ZMESSAGECOUNTER"] or 0) if existing else 0) + written}
        previous = existing["ZLASTMESSAGEDATE"] if existing else None
        if previous is None or last_date >= previous:
            values.update({"ZLASTMESSAGE": last_pk, "ZLASTMESSAGEDATE": last_date})
            if not self.conv["lasttext_is_blob"]:
                values["ZLASTMESSAGETEXT"] = last_text
        self.update("ZWACHATSESSION", session, values)
        return session

    def _message(self, chat: Chat, session: int, message: Message, member: int | None, archive: Archive,
                 report: Report, media_root: str | None, media_dir: str) -> int:
        conv = self.conv
        kind_type = IOS_TYPE.get(message.kind, 0)
        is_media = message.kind in MEDIA_KINDS
        text = None if is_media else message.text
        if message.kind is Kind.LOCATION and not message.location:
            kind_type, text = 0, message.text or "[Location]"
        if message.kind is Kind.CONTACT and not message.vcard:
            kind_type, text = 0, message.text or "[Contact card]"
        push_name = None
        if not message.from_me and message.sender_jid and not conv["pushname_is_blob"]:
            push_name = archive.names.get(message.sender_jid)
        peer = chat.lid if conv["from_lid"] and chat.lid else chat.jid
        fallback = conv["msg_flags_out"] if message.from_me else conv["msg_flags_in"]
        pk = self.insert("ZWAMESSAGE", "WAMessage", {
            "ZCHATSESSION": session,
            "ZLASTSESSION": session,
            "ZISFROMME": int(message.from_me),
            "ZMESSAGETYPE": kind_type,
            "ZMESSAGESTATUS": conv["msg_status_out"] if message.from_me else conv["msg_status_in"],
            "ZMESSAGEERRORSTATUS": 0,
            "ZSTARRED": int(message.starred),
            "ZFLAGS": conv["flags_by_type"].get(f"{int(message.from_me)}:{kind_type}", fallback),
            "ZSPOTLIGHTSTATUS": conv["msg_spot"],
            "ZDOCID": 0,
            "ZCHILDMESSAGESDELIVEREDCOUNT": 0,
            "ZCHILDMESSAGESPLAYEDCOUNT": 0,
            "ZCHILDMESSAGESREADCOUNT": 0,
            "ZDATAITEMVERSION": conv["msg_dataver"],
            "ZFILTEREDRECIPIENTCOUNT": 0,
            "ZENCRETRYCOUNT": 0,
            "ZGROUPEVENTTYPE": conv["event_out"] if message.from_me else conv["event_in"],
            "ZMESSAGEDATE": cocoa(message.timestamp_ms),
            "ZSENTDATE": cocoa(message.timestamp_ms),
            "ZFROMJID": None if message.from_me else (chat.jid if chat.is_group else peer),
            "ZTOJID": (chat.jid if chat.is_group else peer) if message.from_me else None,
            "ZSTANZAID": message.key_id,
            "ZMEDIASECTIONID": _section(message.timestamp_ms) if is_media else None,
            "ZTEXT": text,
            "ZPUSHNAME": push_name,
            "ZGROUPMEMBER": member,
        })
        wants_item = is_media or (message.kind is Kind.LOCATION and message.location) or \
            (message.kind is Kind.CONTACT and message.vcard)
        if wants_item and "ZWAMEDIAITEM" in self.columns:
            item = self._media_item(pk, message, report, media_root, media_dir)
            if item:
                self.update("ZWAMESSAGE", pk, {"ZMEDIAITEM": item})
        return pk

    def _media_item(self, message_pk: int, message: Message, report: Report, media_root: str | None,
                    media_dir: str) -> int | None:
        conv = self.conv
        values: dict = {"ZMESSAGE": message_pk, "ZCLOUDSTATUS": conv["media_cloud"], "ZMEDIAORIGIN": conv["media_origin"]}
        if message.kind is Kind.LOCATION and message.location:
            values.update({"ZLATITUDE": message.location.latitude, "ZLONGITUDE": message.location.longitude,
                           "ZTITLE": message.location.name})
            return self.insert("ZWAMEDIAITEM", "WAMediaItem", values)
        if message.kind is Kind.CONTACT and message.vcard:
            name = _vcard_name(message.vcard) or message.text
            values.update({"ZVCARDSTRING": message.vcard, "ZVCARDNAME": name, "ZTITLE": name})
            return self.insert("ZWAMEDIAITEM", "WAMediaItem", values)
        media = message.media
        if media is None:
            return None
        values.update({
            "ZFILESIZE": media.size or 0,
            "ZMOVIEDURATION": int(media.duration_s or 0),
            "ZTITLE": media.file_name if message.kind is Kind.DOCUMENT else media.caption,
        })
        if conv["mime_in_vcard"] and media.mime_type:
            values["ZVCARDSTRING"] = media.mime_type
        size = (media.width, media.height) if media.width and media.height else None
        local = _locate(media.android_path, media_root) if media_root else None
        if local:
            name = str(uuid.uuid4())
            stem = f"Media/{media_dir}/{name[0]}/{name[1]}/{name}"
            path = stem + os.path.splitext(local)[1].lower()
            values["ZMEDIALOCALPATH"] = path
            values["ZFILESIZE"] = os.path.getsize(local)
            values["ZVCARDNAME"] = _sha256(local)
            report.media_files.append(MediaFile(source=local, relative_path=MEDIA_PREFIX + path))
            report.media_linked += 1
            thumbnail = self._thumbnail(message.kind, local, name)
            if thumbnail:
                made, measured = thumbnail
                size = size or measured
                values["ZXMPPTHUMBPATH"] = stem + ".thumb"
                report.media_files.append(MediaFile(source=str(made), relative_path=MEDIA_PREFIX + stem + ".thumb"))
                report.thumbnails += 1
        else:
            report.media_missing += 1
        if size and message.kind in VISUAL_KINDS:
            values["ZLATITUDE"], values["ZLONGITUDE"] = size[1], size[0]
        return self.insert("ZWAMEDIAITEM", "WAMediaItem", values)

    def _thumbnail(self, kind: Kind, local: str, name: str) -> tuple[Path, tuple[int, int] | None] | None:
        if self.thumbnails is None:
            return None
        target = self.thumbnails / f"{name}.thumb"
        if kind is Kind.IMAGE:
            measured = thumbs.image(local, target)
            return (target, measured) if measured else None
        if kind in (Kind.VIDEO, Kind.GIF) and thumbs.video(local, target):
            return target, None
        return None


def verify(path: Path) -> list[str]:
    conn = sqlite3.connect(path)
    problems: list[str] = []
    result = conn.execute("PRAGMA integrity_check").fetchone()[0]
    if result != "ok":
        problems.append(f"integrity_check: {result}")
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    for ent, name, maximum in conn.execute("SELECT Z_ENT, Z_NAME, Z_MAX FROM Z_PRIMARYKEY"):
        table = f"ZWA{name[2:].upper()}" if name.startswith("WA") else None
        if table in tables:
            highest = conn.execute(f"SELECT MAX(Z_PK) FROM {table} WHERE Z_ENT=?", (ent,)).fetchone()[0] or 0
            if highest > (maximum or 0):
                problems.append(f"{table}: Z_MAX {maximum} is below the highest Z_PK {highest}")
    if "ZWAMEDIAITEM" in tables:
        broken = conn.execute(
            "SELECT COUNT(*) FROM ZWAMESSAGE m LEFT JOIN ZWAMEDIAITEM i ON i.Z_PK = m.ZMEDIAITEM "
            "WHERE m.ZMEDIAITEM IS NOT NULL AND (i.Z_PK IS NULL OR i.ZMESSAGE <> m.Z_PK)").fetchone()[0]
        if broken:
            problems.append(f"{broken} messages point at a missing or mismatched media item")
    orphans = conn.execute(
        "SELECT COUNT(*) FROM ZWAMESSAGE m LEFT JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION "
        "WHERE s.Z_PK IS NULL").fetchone()[0]
    if orphans:
        problems.append(f"{orphans} messages belong to no chat")
    duplicates = conn.execute(
        "SELECT COUNT(*) FROM (SELECT ZCHATSESSION, ZSTANZAID FROM ZWAMESSAGE WHERE ZSTANZAID IS NOT NULL "
        "GROUP BY 1, 2 HAVING COUNT(*) > 1)").fetchone()[0]
    if duplicates:
        problems.append(f"{duplicates} messages are duplicated within a chat")
    conn.close()
    return problems
