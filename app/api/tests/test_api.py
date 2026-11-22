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

KEY = "test-owner-key"
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

    def put_image(self, name: str, data: bytes, content_type: str) -> None:
        self.blobs[name] = (data, content_type)

    def create_record(self, record: ImageRecord) -> None:
        self.records[record.id] = record

    def get_record(self, image_id: str) -> ImageRecord | None:
        return self.records.get(image_id)

    def enqueue(self, image_id: str) -> None:
        self.queue.append(json.dumps({"id": image_id}))

    def sign_read_url(self, name: str) -> str:
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
    assert "img-src 'self' http://localhost:10000 " in csp
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
    monkeypatch.setenv("OWNER_API_KEY", "k")
    monkeypatch.setenv("PUBLIC_BASE_URL", "http://x")
    monkeypatch.setenv("SAS_TTL_SECONDS", "3600")
    with pytest.raises(RuntimeError, match="SAS_TTL_SECONDS"):
        Settings.from_env()


def test_settings_owner_key_file_wins(monkeypatch, tmp_path: Path):
    keyfile = tmp_path / "owner-key"
    keyfile.write_text("from-file\n")
    monkeypatch.setenv("STORAGE_ACCOUNT_NAME", "acct")
    monkeypatch.setenv("OWNER_API_KEY", "from-env")
    monkeypatch.setenv("OWNER_API_KEY_FILE", str(keyfile))
    monkeypatch.setenv("PUBLIC_BASE_URL", "http://x/")
    s = Settings.from_env()
    assert s.owner_api_key == "from-file"
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
