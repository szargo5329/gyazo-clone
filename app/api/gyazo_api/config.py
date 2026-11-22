"""Runtime configuration, read once from the environment.

Two storage auth modes (D-019):
- ``key``:   local Azurite. Signs SAS with the account key (Azurite's public dev key).
- ``entra``: Azure. DefaultAzureCredential (workload identity); SAS signed with a
             user-delegation key. Shared keys are disabled on the real account.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None or value == "":
        raise RuntimeError(f"missing required environment variable {name}")
    return value


MIN_KEY_LENGTH = 16


def _owner_key() -> str:
    # In AKS the key is a file mounted by the Secrets Store CSI driver (D-001);
    # locally it can be an env var. The file wins so the secret never sits in env.
    path = os.environ.get("OWNER_API_KEY_FILE")
    key = Path(path).read_text(encoding="utf-8").strip() if path else _env("OWNER_API_KEY")
    # Fail loudly at startup rather than silently rejecting every upload (empty file)
    # or accepting a guessable key.
    if len(key) < MIN_KEY_LENGTH:
        raise RuntimeError(f"owner API key must be at least {MIN_KEY_LENGTH} characters")
    return key


@dataclass(frozen=True)
class Settings:
    auth_mode: str
    account_name: str
    blob_endpoint: str
    blob_public_endpoint: str
    queue_endpoint: str
    table_endpoint: str
    account_key: str | None
    container: str
    queue: str
    table: str
    owner_api_key: str
    public_base_url: str
    max_upload_bytes: int
    sas_ttl_seconds: int
    ensure_resources: bool
    static_dir: Path | None

    @classmethod
    def from_env(cls) -> Settings:
        mode = _env("STORAGE_AUTH_MODE", "entra")
        if mode not in ("key", "entra"):
            raise RuntimeError("STORAGE_AUTH_MODE must be 'key' or 'entra'")
        account = _env("STORAGE_ACCOUNT_NAME")
        blob = _env("STORAGE_BLOB_ENDPOINT", f"https://{account}.blob.core.windows.net")
        ttl = int(_env("SAS_TTL_SECONDS", "300"))
        if not 0 < ttl <= 300:
            raise RuntimeError("SAS_TTL_SECONDS must be between 1 and 300 (D-004)")
        static = os.environ.get("STATIC_DIR")
        return cls(
            auth_mode=mode,
            account_name=account,
            blob_endpoint=blob,
            # The browser follows the redirect, so it may need a different host than
            # the API uses internally (e.g. localhost vs the compose service name).
            blob_public_endpoint=_env("STORAGE_BLOB_PUBLIC_ENDPOINT", blob),
            queue_endpoint=_env(
                "STORAGE_QUEUE_ENDPOINT", f"https://{account}.queue.core.windows.net"
            ),
            table_endpoint=_env(
                "STORAGE_TABLE_ENDPOINT", f"https://{account}.table.core.windows.net"
            ),
            account_key=_env("STORAGE_ACCOUNT_KEY") if mode == "key" else None,
            container=_env("STORAGE_CONTAINER", "images"),
            queue=_env("STORAGE_QUEUE", "image-jobs"),
            table=_env("STORAGE_TABLE", "images"),
            owner_api_key=_owner_key(),
            public_base_url=_env("PUBLIC_BASE_URL").rstrip("/"),
            max_upload_bytes=int(_env("MAX_UPLOAD_BYTES", str(10 * 1024 * 1024))),
            sas_ttl_seconds=ttl,
            ensure_resources=os.environ.get("ENSURE_RESOURCES", "false").lower() == "true",
            static_dir=Path(static) if static else None,
        )
