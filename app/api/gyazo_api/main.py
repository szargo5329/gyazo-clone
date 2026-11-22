"""FastAPI app: upload (owner key), public short links, image status, static web UI."""

# No `from __future__ import annotations` here: FastAPI resolves Depends() in
# Annotated hints at runtime, and closures (get_store) are not resolvable from strings.

import hmac
import logging
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

from .config import Settings
from .images import blob_name, is_valid_id, new_image_id, sniff_image_type
from .storage import AzureStore, ImageRecord, Store

log = logging.getLogger("gyazo_api")


def build_csp(blob_public_endpoint: str) -> str:
    # Strict CSP: the owner key lives in localStorage, so no inline or third-party
    # scripts may run (spec). Images come from storage via the SAS redirect.
    from urllib.parse import urlsplit

    parts = urlsplit(blob_public_endpoint)
    storage_origin = f"{parts.scheme}://{parts.netloc}"
    return "; ".join(
        [
            "default-src 'self'",
            "script-src 'self'",
            "style-src 'self'",
            f"img-src 'self' {storage_origin} blob: data:",
            "connect-src 'self'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'self'",
            "frame-ancestors 'none'",
        ]
    )


def create_app(settings: Settings, store: Store) -> FastAPI:
    app = FastAPI(title="gyazo-clone API", docs_url=None, redoc_url=None, openapi_url=None)
    csp = build_csp(settings.blob_public_endpoint)

    @app.middleware("http")
    async def security_headers(request: Request, call_next: Callable):
        response = await call_next(request)
        response.headers["Content-Security-Policy"] = csp
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        return response

    def get_store() -> Store:
        return store

    def require_owner(x_api_key: Annotated[str | None, Header()] = None) -> None:
        # Constant-time compare: no timing oracle on the key.
        if not x_api_key or not hmac.compare_digest(
            x_api_key.encode(), settings.owner_api_key.encode()
        ):
            raise HTTPException(status_code=401, detail="invalid or missing API key")

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}  # liveness: process is up; no dependencies

    @app.get("/readyz")
    def readyz(s: Annotated[Store, Depends(get_store)]) -> JSONResponse:
        try:
            s.ping()
        except Exception:  # readiness must never crash the probe
            log.exception("readiness check failed")
            return JSONResponse({"status": "unavailable"}, status_code=503)
        return JSONResponse({"status": "ready"})

    @app.post("/upload", status_code=201, dependencies=[Depends(require_owner)])
    def upload(file: UploadFile, s: Annotated[Store, Depends(get_store)]) -> dict[str, str]:
        # Read at most cap+1 bytes: enough to detect "too large" without buffering more.
        data = file.file.read(settings.max_upload_bytes + 1)
        if len(data) > settings.max_upload_bytes:
            raise HTTPException(status_code=413, detail="file too large")
        content_type = sniff_image_type(data[:16])
        if content_type is None:
            raise HTTPException(status_code=415, detail="only PNG, JPEG, GIF or WebP")
        image_id = new_image_id()
        s.put_image(blob_name(image_id), data, content_type)
        s.create_record(
            ImageRecord(
                id=image_id,
                status="pending",
                content_type=content_type,
                size=len(data),
                created_at=datetime.now(UTC).isoformat(),
            )
        )
        s.enqueue(image_id)
        log.info("uploaded id=%s type=%s size=%d", image_id, content_type, len(data))
        return {"id": image_id, "url": f"{settings.public_base_url}/i/{image_id}"}

    @app.get("/i/{image_id}")
    def view(image_id: str, s: Annotated[Store, Depends(get_store)]) -> RedirectResponse:
        if not is_valid_id(image_id) or s.get_record(image_id) is None:
            raise HTTPException(status_code=404, detail="not found")
        # Bytes never stream through the API: 302 to a short-lived read-only SAS (D-004).
        return RedirectResponse(
            s.sign_read_url(blob_name(image_id)),
            status_code=302,
            headers={"Cache-Control": "no-store"},
        )

    @app.get("/api/images/{image_id}")
    def status(image_id: str, s: Annotated[Store, Depends(get_store)]) -> dict:
        record = s.get_record(image_id) if is_valid_id(image_id) else None
        if record is None:
            raise HTTPException(status_code=404, detail="not found")
        return {
            "id": record.id,
            "status": record.status,
            "content_type": record.content_type,
            "size": record.size,
            "width": record.width,
            "height": record.height,
            "url": f"{settings.public_base_url}/i/{record.id}",
            "thumbnail_url": s.sign_read_url(record.thumb_blob) if record.thumb_blob else None,
        }

    if settings.static_dir and settings.static_dir.is_dir():
        # Mounted last so API routes win; html=True serves index.html at "/".
        app.mount("/", StaticFiles(directory=settings.static_dir, html=True), name="web")

    return app


def app_factory() -> FastAPI:
    """Entry point for uvicorn: ``uvicorn gyazo_api.main:app_factory --factory``."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    # The Azure SDK logs every HTTP request/response at INFO; keep only warnings.
    logging.getLogger("azure").setLevel(logging.WARNING)
    settings = Settings.from_env()
    store = AzureStore(settings)
    if settings.ensure_resources:
        store.ensure_resources()
    return create_app(settings, store)
