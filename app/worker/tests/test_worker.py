"""Worker tests: real Pillow processing, fake queue/storage backend."""

from __future__ import annotations

import base64
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


@pytest.mark.parametrize("size", [(10_000, 10_000), (8_000, 7_500)])  # 100 MP and 60 MP
def test_processor_rejects_decompression_bomb(size):
    # Tiny file, huge declared dimensions: refused from the header, before decoding.
    # 60 MP sits in Pillow's warn-only band (40-80 MP), so this proves our own hard cap.
    bomb = image_bytes("PNG", size=size, mode="1")
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


VALID_ID = "A1b2C3d4E5f6G7h8I9j0Kl"


def b64(text: str) -> str:
    return base64.b64encode(text.encode()).decode()


@pytest.mark.parametrize(
    ("content", "expected"),
    [
        (b64(f'{{"id": "{VALID_ID}"}}'), VALID_ID),
        (b64('{"id": "abc123"}'), None),  # wrong length
        (b64('{"id": "' + "é" * 22 + '"}'), None),  # non-ASCII letters
        (b64('{"id": "../x"}'), None),
        (b64('{"id": 5}'), None),
        (b64("{}"), None),
        (b64("[]"), None),
        (b64("not json"), None),
        ("%%% not base64 %%%", None),
        (f'{{"id": "{VALID_ID}"}}', None),  # plain JSON: wrong encoding, refused
    ],
)
def test_parse_message(content, expected):
    assert parse_message(content) == expected


class FailingAfterProcess(FakeBackend):
    def __init__(self, blobs, fail_on: str) -> None:
        super().__init__(blobs)
        self.fail_on = fail_on
        self.give_up_fails = False

    def upload_thumbnail(self, name, data):
        if self.fail_on == "upload":
            raise ConnectionError("blob write failed")
        super().upload_thumbnail(name, data)

    def update_record(self, image_id, fields):
        if self.fail_on == "update" or (self.give_up_fails and fields.get("status") == "failed"):
            raise ConnectionError("table write failed")
        super().update_record(image_id, fields)


@pytest.mark.parametrize("fail_on", ["upload", "update"])
def test_handle_errors_after_processing_retry_instead_of_crashing(fail_on):
    backend = FailingAfterProcess({"img/abc": image_bytes("PNG")}, fail_on)
    job = Job("abc", 1, raw=None)
    assert handle(job, backend, ThumbnailProcessor()) == "retry"  # no exception escapes
    assert backend.deleted == []


def test_handle_errors_after_processing_give_up_at_max_attempts():
    backend = FailingAfterProcess({"img/abc": image_bytes("PNG")}, "upload")
    job = Job("abc", MAX_ATTEMPTS, raw=None)
    assert handle(job, backend, ThumbnailProcessor()) == "failed"
    assert backend.records["abc"]["status"] == "failed" and backend.deleted == [job]


def test_handle_never_raises_even_if_marking_failed_fails():
    backend = FailingAfterProcess({"img/abc": image_bytes("PNG")}, "upload")
    backend.give_up_fails = True
    assert handle(Job("abc", MAX_ATTEMPTS, raw=None), backend, ThumbnailProcessor()) == "retry"


def test_handle_drops_job_that_exceeded_attempts_before_any_work():
    """A job that crashes the process (e.g. OOM) never raises in Python, but its
    dequeue count climbs: it must be retired without touching the image again."""
    backend = FakeBackend({})  # download would KeyError if called
    job = Job("abc", MAX_ATTEMPTS + 1, raw=None)
    assert handle(job, backend, ThumbnailProcessor()) == "failed"
    assert backend.records["abc"] == {"status": "failed", "error": "too many attempts"}
    assert backend.deleted == [job]


def test_worker_queue_client_keeps_encoding_and_parses_api_messages(monkeypatch):
    """Regression twin of the API test: the worker's client must carry the same policy,
    and what the API's policy produces must parse here."""
    from azure.storage.queue import TextBase64EncodePolicy

    from gyazo_worker.worker import AzureBackend

    monkeypatch.setenv("STORAGE_AUTH_MODE", "key")
    monkeypatch.setenv("STORAGE_ACCOUNT_NAME", "devstoreaccount1")
    monkeypatch.setenv("STORAGE_ACCOUNT_KEY", "dGVzdA==")
    monkeypatch.setenv("STORAGE_QUEUE_ENDPOINT", "http://azurite:10001/devstoreaccount1")
    backend = AzureBackend()
    assert isinstance(backend._queue._message_encode_policy, TextBase64EncodePolicy)
    producer = TextBase64EncodePolicy()
    producer.configure(require_encryption=False, key_encryption_key=None, resolver=None)
    assert parse_message(producer(f'{{"id": "{VALID_ID}"}}')) == VALID_ID
