"""Route tests against an in-memory store: behaviour, auth and validation."""

from __future__ import annotations

import json
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest
from fastapi.testclient import TestClient

from gyazo_api.config import Settings
from gyazo_api.images import ID_LENGTH, is_valid_id, new_image_id, sniff_image_type
from gyazo_api.main import create_app
from gyazo_api.storage import ImageRecord

KEY = "test-owner-key-0123456789"
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32
JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 32
GIF = b"GIF89a" + b"\x00" * 32
WEBP = b"RIFF\x24\x00\x00\x00WEBPVP8 " + b"\x00" * 32


class FakeStore:
    def __init__(self) -> None:
        self.blobs: dict[str, tuple[bytes, str]] = {}
        self.records: dict[str, ImageRecord] = {}
        self.queue: list[str] = []
        self.healthy = True
        self.signing_works = True

    def put_image(self, name: str, data: bytes, content_type: str) -> None:
        self.blobs[name] = (data, content_type)

    def create_record(self, record: ImageRecord) -> None:
        self.records[record.id] = record

    def get_record(self, image_id: str) -> ImageRecord | None:
        return self.records.get(image_id)

    def enqueue(self, image_id: str) -> None:
        self.queue.append(json.dumps({"id": image_id}))

    def sign_read_url(self, name: str) -> str:
        if not self.signing_works:
            raise RuntimeError("Entra token endpoint unreachable")
        return f"http://storage.test/images/{name}?sig=fake"

    def ping(self) -> None:
        if not self.healthy:
            raise RuntimeError("storage down")


def make_settings(**overrides) -> Settings:
    base = dict(
        auth_mode="key",
        account_name="devstoreaccount1",
        blob_endpoint="http://azurite:10000/devstoreaccount1",
        blob_public_endpoint="http://localhost:10000/devstoreaccount1",
        queue_endpoint="http://azurite:10001/devstoreaccount1",
        table_endpoint="http://azurite:10002/devstoreaccount1",
        account_key="unused",
        container="images",
        queue="image-jobs",
        table="images",
        owner_api_key=KEY,
        public_base_url="http://localhost:8000",
        max_upload_bytes=1024,
        sas_ttl_seconds=300,
        ensure_resources=False,
        static_dir=None,
    )
    return Settings(**(base | overrides))


@pytest.fixture
def store() -> FakeStore:
    return FakeStore()


@pytest.fixture
def client(store: FakeStore) -> TestClient:
    return TestClient(create_app(make_settings(), store))


def upload(client: TestClient, data: bytes, key: str | None = KEY, name: str = "x.png"):
    headers = {"X-API-Key": key} if key is not None else {}
    return client.post("/upload", files={"file": (name, data)}, headers=headers)


# --- pure helpers ---------------------------------------------------------------


def test_ids_are_22_char_base62_and_unique():
    ids = {new_image_id() for _ in range(1000)}
    assert len(ids) == 1000
    assert all(len(i) == ID_LENGTH and is_valid_id(i) for i in ids)


@pytest.mark.parametrize("bad", ["", "short", "a" * 21, "a" * 23, "../../etc/passwd" + "a" * 6])
def test_invalid_ids_rejected(bad):
    assert not is_valid_id(bad)


@pytest.mark.parametrize(
    ("data", "expected"),
    [
        (PNG, "image/png"),
        (JPEG, "image/jpeg"),
        (GIF, "image/gif"),
        (b"GIF87a" + b"\x00" * 10, "image/gif"),
        (WEBP, "image/webp"),
        (b"RIFF\x24\x00\x00\x00WAVEfmt ", None),  # RIFF but not WebP
        (b"<svg xmlns=", None),  # SVG can carry script: never accepted
        (b"", None),
    ],
)
def test_sniff_image_type(data, expected):
    assert sniff_image_type(data) == expected


# --- upload ----------------------------------------------------------------------


@pytest.mark.parametrize(("data", "ctype"), [(PNG, "image/png"), (WEBP, "image/webp")])
def test_upload_stores_blob_record_and_job(client, store, data, ctype):
    r = upload(client, data)
    assert r.status_code == 201
    body = r.json()
    image_id = body["id"]
    assert is_valid_id(image_id)
    assert body["url"] == f"http://localhost:8000/i/{image_id}"
    assert store.blobs[f"img/{image_id}"] == (data, ctype)
    rec = store.records[image_id]
    assert (rec.status, rec.content_type, rec.size) == ("pending", ctype, len(data))
    assert json.loads(store.queue[0]) == {"id": image_id}


def test_upload_ignores_client_filename_and_type(client, store):
    r = client.post(
        "/upload",
        files={"file": ("evil.html", PNG, "text/html")},
        headers={"X-API-Key": KEY},
    )
    assert r.status_code == 201
    assert store.records[r.json()["id"]].content_type == "image/png"


@pytest.mark.parametrize("key", [None, "", "wrong", KEY + "x"])
def test_upload_requires_owner_key(client, store, key):
    r = upload(client, PNG, key=key)
    assert r.status_code == 401
    assert not store.blobs and not store.queue


def test_upload_rejects_non_images(client, store):
    r = upload(client, b"%PDF-1.7 not an image", name="x.png")
    assert r.status_code == 415
    assert not store.blobs


def test_upload_rejects_oversize(client, store):
    r = upload(client, PNG + b"\x00" * 2048)
    assert r.status_code == 413
    assert not store.blobs


def test_upload_at_exact_limit_is_accepted(client):
    assert upload(client, PNG + b"\x00" * (1024 - len(PNG))).status_code == 201


# --- view / status ---------------------------------------------------------------


def test_view_redirects_to_signed_url_without_caching(client):
    image_id = upload(client, PNG).json()["id"]
    r = client.get(f"/i/{image_id}", follow_redirects=False)
    assert r.status_code == 302
    assert r.headers["location"] == f"http://storage.test/images/img/{image_id}?sig=fake"
    assert r.headers["cache-control"] == "no-store"


def test_view_needs_no_key(client):
    image_id = upload(client, PNG).json()["id"]
    assert client.get(f"/i/{image_id}", follow_redirects=False).status_code == 302


@pytest.mark.parametrize("image_id", ["A" * 22, "not-an-id", "a" * 40])
def test_view_unknown_or_malformed_is_404(client, image_id):
    assert client.get(f"/i/{image_id}", follow_redirects=False).status_code == 404


def test_status_pending_then_ready_with_thumbnail(client, store):
    image_id = upload(client, PNG).json()["id"]
    body = client.get(f"/api/images/{image_id}").json()
    assert body["status"] == "pending" and body["thumbnail_url"] is None
    rec = store.records[image_id]
    rec.status, rec.width, rec.height, rec.thumb_blob = "ready", 10, 20, f"thumb/{image_id}.webp"
    body = client.get(f"/api/images/{image_id}").json()
    assert (body["status"], body["width"], body["height"]) == ("ready", 10, 20)
    assert body["thumbnail_url"].endswith(f"thumb/{image_id}.webp?sig=fake")


def test_status_unknown_is_404(client):
    assert client.get("/api/images/" + "B" * 22).status_code == 404


# --- health, headers, static -----------------------------------------------------


def test_health_and_readiness(client, store):
    assert client.get("/healthz").json() == {"status": "ok"}
    assert client.get("/readyz").status_code == 200
    store.healthy = False
    assert client.get("/readyz").status_code == 503
    assert client.get("/healthz").status_code == 200  # liveness ignores dependencies


def test_security_headers_on_every_response(client):
    r = client.get("/healthz")
    csp = r.headers["content-security-policy"]
    assert "script-src 'self'" in csp
    assert "'unsafe-inline'" not in csp
    assert "img-src 'self' http://localhost:10000;" in csp  # no blob:/data:
    assert "frame-ancestors 'none'" in csp
    assert r.headers["x-content-type-options"] == "nosniff"
    assert r.headers["referrer-policy"] == "no-referrer"


def test_no_api_docs_exposed(client):
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(path).status_code == 404


def test_serves_static_ui_without_shadowing_api(store, tmp_path: Path):
    (tmp_path / "index.html").write_text("<!doctype html><title>ui</title>")
    c = TestClient(create_app(make_settings(static_dir=tmp_path), store))
    assert "<title>ui</title>" in c.get("/").text
    assert c.get("/healthz").json() == {"status": "ok"}


def test_settings_reject_long_sas_ttl(monkeypatch):
    monkeypatch.setenv("STORAGE_ACCOUNT_NAME", "acct")
    monkeypatch.setenv("OWNER_API_KEY", "k" * 16)
    monkeypatch.setenv("PUBLIC_BASE_URL", "http://x")
    monkeypatch.setenv("SAS_TTL_SECONDS", "3600")
    with pytest.raises(RuntimeError, match="SAS_TTL_SECONDS"):
        Settings.from_env()


def test_settings_owner_key_file_wins(monkeypatch, tmp_path: Path):
    keyfile = tmp_path / "owner-key"
    keyfile.write_text("from-file-0123456789\n")
    monkeypatch.setenv("STORAGE_ACCOUNT_NAME", "acct")
    monkeypatch.setenv("OWNER_API_KEY", "from-env")
    monkeypatch.setenv("OWNER_API_KEY_FILE", str(keyfile))
    monkeypatch.setenv("PUBLIC_BASE_URL", "http://x/")
    s = Settings.from_env()
    assert s.owner_api_key == "from-file-0123456789"
    assert s.public_base_url == "http://x"
    assert s.auth_mode == "entra" and s.account_key is None  # safe default


def test_signed_url_shape_key_mode():
    """Real SAS generation (no network): read-only, ≤5 min, public endpoint host."""
    from gyazo_api.storage import AzureStore

    # Azurite's documented public dev key; not a secret.
    azurite_key = (
        "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
    )
    s = make_settings(account_key=azurite_key)
    url = AzureStore(s).sign_read_url("img/abc")
    parts = urlsplit(url)
    assert url.startswith("http://localhost:10000/devstoreaccount1/images/img/abc?")
    q = parse_qs(parts.query)
    assert q["sp"] == ["r"]
    assert "se" in q and "sig" in q


# --- review fixes: early upload guard, signing failures, key length, entra signer -----


def test_upload_guard_rejects_before_reading_body(client, store):
    """Key and size are checked from headers alone, before multipart parsing spools it."""
    big = {
        "content-length": str(10 * 1024 * 1024),
        "content-type": "multipart/form-data; boundary=x",
    }
    r = client.post("/upload", content=b"", headers=big)
    assert r.status_code == 401  # no key: rejected before size is even considered
    r = client.post("/upload", content=b"", headers=big | {"X-API-Key": KEY})
    assert r.status_code == 413
    assert r.headers["content-security-policy"]  # early responses keep security headers
    assert not store.blobs


def test_upload_guard_requires_content_length(client):
    def chunks():
        yield PNG

    r = client.post("/upload", content=chunks(), headers={"X-API-Key": KEY})
    assert r.status_code == 411


def test_401_does_not_echo_the_key(client):
    r = upload(client, PNG, key="wrong-key-guess-123")
    assert KEY not in r.text and "wrong-key-guess-123" not in r.text
    assert KEY not in str(r.headers)


def test_unknown_and_malformed_ids_look_identical(client):
    a = client.get("/i/" + "A" * 22, follow_redirects=False)
    b = client.get("/i/not-an-id", follow_redirects=False)
    assert (a.status_code, a.json()) == (b.status_code, b.json()) == (404, {"detail": "not found"})


def test_signing_failure_is_503_not_500(client, store):
    image_id = upload(client, PNG).json()["id"]
    store.signing_works = False
    assert client.get(f"/i/{image_id}", follow_redirects=False).status_code == 503
    store.records[image_id].thumb_blob = "thumb/x.webp"
    assert client.get(f"/api/images/{image_id}").status_code == 503


@pytest.mark.parametrize("key", ["", "short", "x" * 15])
def test_settings_reject_weak_owner_key(monkeypatch, key):
    monkeypatch.setenv("STORAGE_ACCOUNT_NAME", "acct")
    monkeypatch.setenv("OWNER_API_KEY", key)
    monkeypatch.setenv("PUBLIC_BASE_URL", "http://x")
    with pytest.raises(RuntimeError):
        Settings.from_env()


class StubBlobService:
    """Stands in for BlobServiceClient.get_user_delegation_key (Entra path, D-019)."""

    def __init__(self) -> None:
        self.calls: list[tuple] = []

    def get_user_delegation_key(self, start, expiry):
        from azure.storage.blob import UserDelegationKey

        self.calls.append((start, expiry))
        k = UserDelegationKey()
        k.signed_oid = "11111111-1111-1111-1111-111111111111"
        k.signed_tid = "22222222-2222-2222-2222-222222222222"
        k.signed_start = start.strftime("%Y-%m-%dT%H:%M:%SZ")
        k.signed_expiry = expiry.strftime("%Y-%m-%dT%H:%M:%SZ")
        k.signed_service = "b"
        k.signed_version = "2025-01-05"
        k.value = "c2VjcmV0LWtleS1ieXRlcy1mb3ItdGVzdHM="  # base64 test bytes
        return k


def entra_store():
    from gyazo_api.storage import AzureStore

    s = make_settings(
        auth_mode="entra",
        account_key=None,
        account_name="stacct",
        blob_endpoint="https://stacct.blob.core.windows.net",
        blob_public_endpoint="https://stacct.blob.core.windows.net",
    )
    store = AzureStore.__new__(AzureStore)  # skip __init__: no real credential or clients
    import threading
    from datetime import UTC, datetime

    store._s = s
    store._blob_svc = StubBlobService()
    store._udk = None
    store._udk_expiry = datetime.min.replace(tzinfo=UTC)
    store._udk_lock = threading.Lock()
    return store


def test_entra_signing_uses_delegation_key_and_caches_it():
    store = entra_store()
    urls = [store.sign_read_url(f"img/{i}") for i in range(5)]
    assert len(store._blob_svc.calls) == 1  # one key fetch signs many URLs
    q = parse_qs(urlsplit(urls[0]).query)
    assert urls[0].startswith("https://stacct.blob.core.windows.net/images/img/0?")
    assert q["sp"] == ["r"]
    assert q["skoid"] == ["11111111-1111-1111-1111-111111111111"]  # user-delegation SAS
    assert q["sktid"] == ["22222222-2222-2222-2222-222222222222"]
    start, expiry = store._blob_svc.calls[0]
    assert (expiry - start).total_seconds() <= 2 * 3600


def test_entra_key_refreshed_before_expiry():
    from datetime import UTC, datetime, timedelta

    store = entra_store()
    store.sign_read_url("img/a")
    store._udk_expiry = datetime.now(UTC) + timedelta(minutes=9)  # inside the 10-min margin
    store.sign_read_url("img/b")
    assert len(store._blob_svc.calls) == 2


def test_entra_sas_never_outlives_ttl():
    from datetime import UTC, datetime

    store = entra_store()
    q = parse_qs(urlsplit(store.sign_read_url("img/a")).query)
    se = datetime.strptime(q["se"][0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
    assert (se - datetime.now(UTC)).total_seconds() <= 300


def test_queue_messages_are_really_base64_encoded():
    """Regression: QueueServiceClient.get_queue_client() dropped the encode policy, so
    "pinned base64" was silently plain text. Check what actually goes on the wire."""
    import base64
    import json as _json

    from azure.storage.queue import TextBase64EncodePolicy

    from gyazo_api.storage import AzureStore

    store = AzureStore(make_settings(account_key="dGVzdA=="))
    policy = store._queue._message_encode_policy
    assert isinstance(policy, TextBase64EncodePolicy)
    policy.configure(require_encryption=False, key_encryption_key=None, resolver=None)
    wire = policy('{"id": "A1b2C3d4E5f6G7h8I9j0Kl"}')
    assert _json.loads(base64.b64decode(wire)) == {"id": "A1b2C3d4E5f6G7h8I9j0Kl"}
