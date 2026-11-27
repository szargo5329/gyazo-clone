"""End-to-end smoke test against a running stack (local compose now, AKS from M3).

    OWNER_API_KEY=... [PUBLIC_BASE_URL=...] uv run python scripts/smoke.py [base_url]

Checks: auth and validation reject bad uploads; a real PNG uploads; the worker marks it
ready with a thumbnail; /i/<id> redirects to a read-only SAS that returns the same bytes;
a tampered SAS is refused; unknown IDs are 404; security headers are present.
"""

from __future__ import annotations

import io
import os
import sys
import time

import httpx
from PIL import Image


def check(cond: bool, msg: str) -> None:
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond:
        sys.exit(1)


def main() -> None:
    base = (sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8000").rstrip("/")
    key = os.environ["OWNER_API_KEY"]
    buf = io.BytesIO()
    Image.new("RGB", (1200, 600), (37, 99, 235)).save(buf, format="PNG")
    png = buf.getvalue()

    with httpx.Client(base_url=base, timeout=20) as c:
        r = c.post("/upload", files={"file": ("a.png", png)})
        check(r.status_code == 401, f"upload without key -> 401 (got {r.status_code})")
        r = c.post("/upload", files={"file": ("a.png", png)}, headers={"X-API-Key": "wrong"})
        check(r.status_code == 401, f"upload with wrong key -> 401 (got {r.status_code})")
        r = c.post("/upload", files={"file": ("a.png", b"hello")}, headers={"X-API-Key": key})
        check(r.status_code == 415, f"non-image named .png -> 415 (got {r.status_code})")

        r = c.post("/upload", files={"file": ("a.png", png)}, headers={"X-API-Key": key})
        check(r.status_code == 201, f"valid PNG -> 201 (got {r.status_code})")
        body = r.json()
        image_id, url = body["id"], body["url"]
        # Behind a port-forward the API still builds links from its PUBLIC_BASE_URL.
        public = os.environ.get("PUBLIC_BASE_URL", base).rstrip("/")
        check(url == f"{public}/i/{image_id}", f"link format {url}")

        status: dict = {}
        for _ in range(30):
            status = c.get(f"/api/images/{image_id}").json()
            if status["status"] != "pending":
                break
            time.sleep(1)
        check(status["status"] == "ready", f"worker processed image (status={status['status']})")
        check((status["width"], status["height"]) == (1200, 600), "metadata 1200x600")
        thumb = httpx.get(status["thumbnail_url"], timeout=20)
        with Image.open(io.BytesIO(thumb.content)) as t:
            check(t.format == "WEBP" and t.size == (320, 160), f"thumbnail WebP {t.size}")

        r = c.get(f"/i/{image_id}")
        check(r.status_code == 302, f"view -> 302 (got {r.status_code})")
        check(r.headers.get("cache-control") == "no-store", "redirect not cacheable")
        sas = r.headers["location"]
        got = httpx.get(sas, timeout=20)
        check(got.status_code == 200 and got.content == png, "SAS URL returns identical bytes")
        check(got.headers.get("content-type") == "image/png", "blob served as image/png")
        bad = httpx.get(sas.replace("sp=r", "sp=rw"), timeout=20)
        check(bad.status_code == 403, f"tampered SAS refused (got {bad.status_code})")

        r = c.get("/i/" + "A" * 22)
        check(r.status_code == 404, f"unknown id -> 404 (got {r.status_code})")
        csp = c.get("/").headers.get("content-security-policy", "")
        check("script-src 'self'" in csp and "unsafe-inline" not in csp, "strict CSP on UI")
    print(f"\nAll checks passed. Example link: {url}")


if __name__ == "__main__":
    main()
