"""Worker tests: real Pillow processing, fake queue/storage backend."""

from __future__ import annotations

import io

import pytest
from PIL import Image

from gyazo_worker.processor import THUMB_MAX_PX, InvalidImageError, ThumbnailProcessor
from gyazo_worker.worker import MAX_ATTEMPTS, Job, handle, parse_message


def image_bytes(fmt: str, size=(800, 400), mode="RGB", frames: int = 1) -> bytes:
    out = io.BytesIO()
    imgs = [Image.new(mode, size, color=i * 40) for i in range(frames)]
    if frames > 1:
        imgs[0].save(out, format=fmt, save_all=True, append_images=imgs[1:])
    else:
        imgs[0].save(out, format=fmt)
    return out.getvalue()


class FakeBackend:
    def __init__(self, blobs: dict[str, bytes]) -> None:
        self.blobs = blobs
        self.records: dict[str, dict] = {}
        self.deleted: list[Job] = []
        self.fail_download = False

    def receive(self, max_messages: int) -> list[Job]:
        return []

    def delete(self, job: Job) -> None:
        self.deleted.append(job)

    def download(self, name: str) -> bytes:
        if self.fail_download:
            raise ConnectionError("storage blip")
        return self.blobs[name]

    def upload_thumbnail(self, name: str, data: bytes) -> None:
        self.blobs[name] = data

    def update_record(self, image_id: str, fields: dict) -> None:
        self.records.setdefault(image_id, {}).update(fields)


@pytest.mark.parametrize(
    ("fmt", "mode", "frames"),
    [
        ("PNG", "RGB", 1),
        ("PNG", "RGBA", 1),
        ("JPEG", "RGB", 1),
        ("GIF", "P", 3),
        ("WEBP", "RGB", 1),
    ],
)
def test_processor_makes_bounded_webp_thumbnail(fmt, mode, frames):
    result = ThumbnailProcessor().process(image_bytes(fmt, mode=mode, frames=frames))
    assert (result.width, result.height, result.format) == (800, 400, fmt)
    with Image.open(io.BytesIO(result.thumbnail)) as thumb:
        assert thumb.format == "WEBP"
        assert max(thumb.size) <= THUMB_MAX_PX
        assert thumb.size == (320, 160)  # aspect ratio kept


@pytest.mark.parametrize("data", [b"", b"not an image", b"\x89PNG\r\n\x1a\n" + b"\x00" * 50])
def test_processor_rejects_garbage(data):
    with pytest.raises(InvalidImageError):
        ThumbnailProcessor().process(data)


def test_processor_rejects_decompression_bomb():
    # Tiny file, huge declared dimensions: must be refused before decoding.
    bomb = image_bytes("PNG", size=(10_000, 10_000), mode="1")
    with pytest.raises(InvalidImageError):
        ThumbnailProcessor().process(bomb)


def test_handle_success_writes_thumb_and_marks_ready():
    backend = FakeBackend({"img/abc": image_bytes("PNG")})
    job = Job("abc", 1, raw=None)
    assert handle(job, backend, ThumbnailProcessor()) == "done"
    assert "thumb/abc.webp" in backend.blobs
    rec = backend.records["abc"]
    assert rec["status"] == "ready" and (rec["width"], rec["height"]) == (800, 400)
    assert rec["thumb_blob"] == "thumb/abc.webp"
    assert backend.deleted == [job]


def test_handle_is_idempotent_on_redelivery():
    backend = FakeBackend({"img/abc": image_bytes("PNG")})
    for _ in range(2):
        assert handle(Job("abc", 1, raw=None), backend, ThumbnailProcessor()) == "done"
    assert backend.records["abc"]["status"] == "ready"


def test_handle_invalid_image_fails_fast_without_retry():
    backend = FakeBackend({"img/bad": b"garbage"})
    job = Job("bad", 1, raw=None)
    assert handle(job, backend, ThumbnailProcessor()) == "failed"
    assert backend.records["bad"]["status"] == "failed"
    assert backend.deleted == [job]


def test_handle_transient_error_leaves_job_for_retry():
    backend = FakeBackend({})
    backend.fail_download = True
    job = Job("abc", 1, raw=None)
    assert handle(job, backend, ThumbnailProcessor()) == "retry"
    assert backend.deleted == [] and "abc" not in backend.records


def test_handle_poison_message_gives_up_after_max_attempts():
    backend = FakeBackend({})
    backend.fail_download = True
    job = Job("abc", MAX_ATTEMPTS, raw=None)
    assert handle(job, backend, ThumbnailProcessor()) == "failed"
    assert backend.records["abc"]["status"] == "failed"
    assert backend.deleted == [job]


@pytest.mark.parametrize(
    ("content", "expected"),
    [
        ('{"id": "abc123"}', "abc123"),
        ('{"id": "../x"}', None),
        ('{"id": 5}', None),
        ("{}", None),
        ("not json", None),
        ("[]", None),
    ],
)
def test_parse_message(content, expected):
    assert parse_message(content) == expected
