"""Pure helpers: image IDs and content sniffing. No I/O, fully unit-tested."""

from __future__ import annotations

import re
import secrets
import string

_ALPHABET = string.digits + string.ascii_letters  # base62
ID_LENGTH = 22  # 62**22 ≈ 2**131: unguessable, no listing endpoint (D-004)
ID_PATTERN = re.compile(rf"^[0-9A-Za-z]{{{ID_LENGTH}}}$")


def new_image_id() -> str:
    return "".join(secrets.choice(_ALPHABET) for _ in range(ID_LENGTH))


def is_valid_id(value: str) -> bool:
    return bool(ID_PATTERN.match(value))


def sniff_image_type(head: bytes) -> str | None:
    """Return the MIME type from magic bytes, or None. The client's filename and
    Content-Type are never trusted."""
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if head.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if head.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    # RIFF alone also matches WAV/AVI, so check the WEBP form type too.
    if len(head) >= 12 and head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp"
    return None


def blob_name(image_id: str) -> str:
    return f"img/{image_id}"


def thumb_blob_name(image_id: str) -> str:
    return f"thumb/{image_id}.webp"
