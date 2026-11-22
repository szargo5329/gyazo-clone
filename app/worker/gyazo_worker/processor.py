"""Pluggable image processor. The default makes a WebP thumbnail and reads dimensions.

Kept pure (bytes in, result out) so it is unit-testable and swappable later
(e.g. the optional M-AI description processor) without touching queue handling.
"""

from __future__ import annotations

import io
from dataclasses import dataclass
from typing import Protocol

from PIL import Image

# Decompression-bomb guard: refuse images above ~40 MP (Pillow raises DecompressionBombError
# at 2x this). A 10 MB upload cap alone doesn't bound decoded size.
Image.MAX_IMAGE_PIXELS = 40_000_000
THUMB_MAX_PX = 320


class InvalidImageError(ValueError):
    """The bytes aren't a decodable image. Retrying won't help."""


@dataclass(frozen=True)
class ProcessResult:
    width: int
    height: int
    format: str
    thumbnail: bytes  # WebP


class Processor(Protocol):
    def process(self, data: bytes) -> ProcessResult: ...


class ThumbnailProcessor:
    def process(self, data: bytes) -> ProcessResult:
        try:
            with Image.open(io.BytesIO(data)) as probe:
                probe.verify()  # structural check; the image must be reopened afterwards
            with Image.open(io.BytesIO(data)) as img:
                width, height, fmt = img.width, img.height, img.format or "unknown"
                img.seek(0)  # first frame of animated GIF/WebP
                thumb = (
                    img.convert("RGBA") if img.mode in ("P", "LA", "RGBA") else img.convert("RGB")
                )
                thumb.thumbnail((THUMB_MAX_PX, THUMB_MAX_PX))
                out = io.BytesIO()
                thumb.save(out, format="WEBP", quality=80)
        except (
            Image.DecompressionBombError,
            Image.UnidentifiedImageError,
            OSError,
            SyntaxError,
        ) as e:
            raise InvalidImageError(str(e)) from e
        return ProcessResult(width=width, height=height, format=fmt, thumbnail=out.getvalue())
