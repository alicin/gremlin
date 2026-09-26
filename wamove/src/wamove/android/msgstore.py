from __future__ import annotations

import re
import sqlite3
from pathlib import Path

from ..model import MEDIA_KINDS, Archive, Chat, Kind, Location, Media, Message, Participant

TYPES = {
    0: Kind.TEXT,
    1: Kind.IMAGE,
    2: Kind.AUDIO,
    3: Kind.VIDEO,
    4: Kind.CONTACT,
    5: Kind.LOCATION,
    7: Kind.SYSTEM,
    8: Kind.SYSTEM,
    9: Kind.DOCUMENT,
    10: Kind.SYSTEM,
    13: Kind.GIF,
    14: Kind.CONTACT,
    15: Kind.REVOKED,
    16: Kind.LOCATION,
    20: Kind.STICKER,
    24: Kind.SYSTEM,
}
SKIPPED_KINDS = (Kind.SYSTEM, Kind.REVOKED)
SKIPPED_SUFFIXES = ("@broadcast", "@newsletter")
PLACEHOLDER = "[This kind of message could not be moved from Android]"


class MsgstoreError(Exception):
    pass


def _tables(conn: sqlite3.Connection) -> dict[str, set[str]]:
    names = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type IN ('table','view')")]
    return {name: {r[1] for r in conn.execute(f'PRAGMA table_info("{name}")')} for name in names}


def _col(tables: dict[str, set[str]], table: str, column: str, default: str = "NULL") -> str:
    return f"{table}.{column} AS {column}" if column in tables.get(table, ()) else f"{default} AS {column}"


def _resolve(jid: str, contacts: dict[str, str]) -> str | None:
    if not jid.endswith("@s.whatsapp.net"):
        return None
    number = jid.split("@", 1)[0]
    if number in contacts:
        return contacts[number]
    for digits, name in contacts.items():
        if len(digits) >= 9 and (number.endswith(digits[-9:]) or digits.endswith(number[-9:])):
            return name
    return None


def _lid_map(conn: sqlite3.Connection, tables: dict[str, set[str]]) -> dict[str, str]:
    if "lid_row_id" not in tables.get("jid_map", ()):
        return {}
    rows = conn.execute(
        "SELECT l.raw_string, p.raw_string FROM jid_map m "
        "JOIN jid l ON l._id = m.lid_row_id JOIN jid p ON p._id = m.jid_row_id"
    )
    return {lid: pn for lid, pn in rows if lid and pn}


def _lid_names(conn: sqlite3.Connection, tables: dict[str, set[str]]) -> dict[str, str]:
    cols = tables.get("lid_display_name", set())
    key = next((c for c in ("lid_row_id", "jid_row_id") if c in cols), None)
    if not key or "display_name" not in cols:
        return {}
    rows = conn.execute(f"SELECT j.raw_string, d.display_name FROM lid_display_name d JOIN jid j ON j._id = d.{key}")
    return {jid: name for jid, name in rows if jid and name}


def _is_voice(mime: str | None, path: str | None) -> bool:
    return bool(mime and "opus" in mime.lower()) or bool(path and "/WhatsApp Voice Notes/" in path)


def parse(path: Path, contacts: dict[str, str] | None = None) -> Archive:
    contacts = contacts or {}
    conn = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    tables = _tables(conn)
    if not {"message", "chat", "jid"} <= tables.keys():
        raise MsgstoreError("unsupported msgstore.db: update WhatsApp on the Android phone and back up again")

    lid_to_pn = _lid_map(conn, tables)
    pn_to_lid = {pn: lid for lid, pn in lid_to_pn.items()}
    lid_names = _lid_names(conn, tables)

    def phone(jid: str) -> str:
        return lid_to_pn.get(jid, jid)

    def name_of(jid: str) -> str | None:
        return _resolve(jid, contacts) or lid_names.get(jid) or lid_names.get(pn_to_lid.get(jid, ""))

    by_row: dict[int, Chat] = {}
    by_jid: dict[str, Chat] = {}
    chat_sql = (
        f"SELECT chat._id AS id, jid.raw_string AS raw, {_col(tables, 'chat', 'subject')}, "
        f"{_col(tables, 'chat', 'created_timestamp')}, {_col(tables, 'chat', 'archived', '0')} "
        "FROM chat JOIN jid ON jid._id = chat.jid_row_id"
    )
    for row in conn.execute(chat_sql):
        raw = row["raw"]
        if not raw or raw.endswith(SKIPPED_SUFFIXES):
            continue
        jid = phone(raw)
        chat = by_jid.get(jid)
        if chat is None:
            group = jid.endswith("@g.us")
            chat = Chat(
                jid=jid,
                lid=None if group else (raw if raw.endswith("@lid") else pn_to_lid.get(jid)),
                name=row["subject"] if group else name_of(jid),
                is_group=group,
                created_ms=row["created_timestamp"] or None,
                archived=bool(row["archived"]),
            )
            by_jid[jid] = chat
        by_row[row["id"]] = chat

    if "group_participant_user" in tables:
        members = conn.execute(
            f"SELECT g.raw_string AS grp, u.raw_string AS usr, {_col(tables, 'group_participant_user', 'rank', '0')} "
            "FROM group_participant_user JOIN jid g ON g._id = group_participant_user.group_jid_row_id "
            "JOIN jid u ON u._id = group_participant_user.user_jid_row_id"
        )
        for row in members:
            chat = by_jid.get(row["grp"])
            if chat and row["usr"]:
                user = phone(row["usr"])
                chat.participants.append(Participant(jid=user, name=name_of(user), is_admin=bool(row["rank"])))

    joins: list[str] = []
    extra: list[str] = []
    media_cols = ("file_path", "file_size", "mime_type", "media_name", "media_duration", "width", "height",
                  "media_caption")
    location_cols = ("latitude", "longitude", "place_name")
    for table, cols in (("message_media", media_cols), ("message_location", location_cols)):
        if table in tables:
            joins.append(f"LEFT JOIN {table} ON {table}.message_row_id = message._id")
        extra.extend(_col(tables, table, c) for c in cols)
    if "vcard" in tables.get("message_vcard", ()):
        joins.append(
            "LEFT JOIN message_vcard ON message_vcard._id = "
            "(SELECT _id FROM message_vcard v WHERE v.message_row_id = message._id ORDER BY _id LIMIT 1)"
        )
        extra.append("message_vcard.vcard AS vcard")
    else:
        extra.append("NULL AS vcard")

    message_sql = (
        "SELECT message.chat_row_id AS chat_id, message.from_me AS from_me, message.key_id AS key_id, "
        "message.timestamp AS ts, message.message_type AS type, message.text_data AS text, "
        f"{_col(tables, 'message', 'starred', '0')}, sender.raw_string AS sender, {', '.join(extra)} "
        "FROM message LEFT JOIN jid sender ON sender._id = message.sender_jid_row_id "
        f"{' '.join(joins)} ORDER BY message.timestamp, message._id"
    )
    for row in conn.execute(message_sql):
        chat = by_row.get(row["chat_id"])
        if chat is None or not row["key_id"] or row["ts"] is None:
            continue
        kind = TYPES.get(int(row["type"] or 0), Kind.UNKNOWN)
        if kind in SKIPPED_KINDS:
            continue
        media = None
        if row["file_path"] or kind in MEDIA_KINDS:
            media = Media(
                android_path=row["file_path"],
                mime_type=row["mime_type"],
                size=row["file_size"],
                duration_s=row["media_duration"],
                width=row["width"],
                height=row["height"],
                file_name=row["media_name"],
                caption=row["media_caption"] or row["text"],
            )
            if kind is Kind.AUDIO and _is_voice(row["mime_type"], row["file_path"]):
                kind = Kind.VOICE
        location = None
        if kind is Kind.LOCATION and row["latitude"] is not None:
            location = Location(float(row["latitude"]), float(row["longitude"] or 0), row["place_name"])
        text = row["text"]
        if kind is Kind.UNKNOWN and not text:
            text = PLACEHOLDER
        sender = phone(row["sender"]) if row["sender"] and not row["from_me"] else None
        chat.messages.append(Message(
            key_id=row["key_id"],
            from_me=bool(row["from_me"]),
            timestamp_ms=int(row["ts"]),
            kind=kind,
            text=text,
            sender_jid=sender,
            media=media,
            location=location,
            vcard=row["vcard"],
            starred=bool(row["starred"]),
        ))
    conn.close()

    chats = [c for c in by_jid.values() if c.messages]
    names: dict[str, str] = {}
    for chat in chats:
        if not chat.is_group and chat.name:
            names[chat.jid] = chat.name
        for participant in chat.participants:
            if participant.name:
                names.setdefault(participant.jid, participant.name)
        for message in chat.messages:
            if message.sender_jid and message.sender_jid not in names:
                found = name_of(message.sender_jid)
                if found:
                    names[message.sender_jid] = found
    return Archive(chats=chats, names=names, lids=pn_to_lid)


def load_vcf(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    name = None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if line.startswith("BEGIN:VCARD"):
            name = None
        elif line.startswith("FN"):
            name = line.split(":", 1)[1].strip()
        elif line.startswith("TEL") and name:
            digits = re.sub(r"\D", "", line.split(":", 1)[-1])
            if digits:
                result[digits] = name
    return result
