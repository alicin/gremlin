from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


class Kind(str, Enum):
    TEXT = "text"
    IMAGE = "image"
    VIDEO = "video"
    AUDIO = "audio"
    VOICE = "voice"
    DOCUMENT = "document"
    GIF = "gif"
    STICKER = "sticker"
    CONTACT = "contact"
    LOCATION = "location"
    SYSTEM = "system"
    REVOKED = "revoked"
    UNKNOWN = "unknown"


MEDIA_KINDS = frozenset({Kind.IMAGE, Kind.VIDEO, Kind.AUDIO, Kind.VOICE, Kind.DOCUMENT, Kind.GIF, Kind.STICKER})


@dataclass
class Media:
    android_path: str | None
    mime_type: str | None = None
    size: int | None = None
    duration_s: int | None = None
    width: int | None = None
    height: int | None = None
    file_name: str | None = None
    caption: str | None = None


@dataclass
class Location:
    latitude: float
    longitude: float
    name: str | None = None


@dataclass
class Message:
    key_id: str
    from_me: bool
    timestamp_ms: int
    kind: Kind = Kind.TEXT
    text: str | None = None
    sender_jid: str | None = None
    media: Media | None = None
    location: Location | None = None
    vcard: str | None = None
    starred: bool = False


@dataclass
class Participant:
    jid: str
    name: str | None = None
    is_admin: bool = False


@dataclass
class Chat:
    jid: str
    lid: str | None = None
    name: str | None = None
    is_group: bool = False
    created_ms: int | None = None
    archived: bool = False
    participants: list[Participant] = field(default_factory=list)
    messages: list[Message] = field(default_factory=list)

    @property
    def phone(self) -> str | None:
        return self.jid.split("@", 1)[0] if self.jid.endswith("@s.whatsapp.net") else None


@dataclass
class Archive:
    chats: list[Chat]
    names: dict[str, str] = field(default_factory=dict)
    lids: dict[str, str] = field(default_factory=dict)

    def stats(self) -> dict[str, int]:
        return {
            "chats": len(self.chats),
            "groups": sum(c.is_group for c in self.chats),
            "messages": sum(len(c.messages) for c in self.chats),
            "media": sum(1 for c in self.chats for m in c.messages if m.media),
        }
