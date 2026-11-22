"""Storage access behind a small interface, so routes are testable without Azure.

One SAS code path (D-019): ``generate_blob_sas`` is always used; only the signing
material differs. ``key`` mode signs with the account key (Azurite only), ``entra``
mode with a cached user-delegation key obtained via DefaultAzureCredential.
"""

from __future__ import annotations

import contextlib
import json
import threading
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol

from azure.core.credentials import AzureNamedKeyCredential
from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
from azure.data.tables import TableServiceClient
from azure.storage.blob import (
    BlobSasPermissions,
    BlobServiceClient,
    ContentSettings,
    UserDelegationKey,
    generate_blob_sas,
)
from azure.storage.queue import QueueClient, TextBase64EncodePolicy

from .config import Settings

PARTITION_ROW = "meta"  # one entity per image: PartitionKey=<id>, RowKey="meta"


@dataclass
class ImageRecord:
    id: str
    status: str
    content_type: str
    size: int
    created_at: str
    width: int | None = None
    height: int | None = None
    thumb_blob: str | None = None


class Store(Protocol):
    def put_image(self, name: str, data: bytes, content_type: str) -> None: ...
    def create_record(self, record: ImageRecord) -> None: ...
    def get_record(self, image_id: str) -> ImageRecord | None: ...
    def enqueue(self, image_id: str) -> None: ...
    def sign_read_url(self, name: str) -> str: ...
    def ping(self) -> None: ...


def record_from_entity(entity: dict[str, Any]) -> ImageRecord:
    return ImageRecord(
        id=entity["PartitionKey"],
        status=entity["status"],
        content_type=entity["content_type"],
        size=int(entity["size"]),
        created_at=entity["created_at"],
        width=entity.get("width"),
        height=entity.get("height"),
        thumb_blob=entity.get("thumb_blob"),
    )


class AzureStore:
    def __init__(self, s: Settings) -> None:
        self._s = s
        if s.auth_mode == "key":
            assert s.account_key  # noqa: S101 - guaranteed by Settings
            cred: Any = AzureNamedKeyCredential(s.account_name, s.account_key)
        else:
            from azure.identity import DefaultAzureCredential

            cred = DefaultAzureCredential()
        self._blob_svc = BlobServiceClient(s.blob_endpoint, credential=cred)
        self._container = self._blob_svc.get_container_client(s.container)
        # Queue encoding is pinned explicitly in producer and consumer so they can't drift
        # (D-020). QueueClient is built directly: QueueServiceClient.get_queue_client() does
        # NOT pass message_encode_policy through, which silently sent plain text before.
        self._queue = QueueClient(
            s.queue_endpoint,
            s.queue,
            credential=cred,
            message_encode_policy=TextBase64EncodePolicy(),
        )
        self._table = TableServiceClient(s.table_endpoint, credential=cred).get_table_client(
            s.table
        )
        self._udk: UserDelegationKey | None = None
        self._udk_expiry = datetime.min.replace(tzinfo=UTC)
        self._udk_lock = threading.Lock()

    def ensure_resources(self) -> None:
        """Local dev only: in Azure, Terraform owns these and the API can't create them."""
        for create in (
            self._container.create_container,
            self._queue.create_queue,
            self._table.create_table,
        ):
            with contextlib.suppress(ResourceExistsError):
                create()

    def put_image(self, name: str, data: bytes, content_type: str) -> None:
        self._container.upload_blob(
            name,
            data,
            overwrite=False,
            content_settings=ContentSettings(content_type=content_type),
        )

    def create_record(self, record: ImageRecord) -> None:
        entity = {k: v for k, v in record.__dict__.items() if v is not None and k != "id"}
        entity |= {"PartitionKey": record.id, "RowKey": PARTITION_ROW}
        self._table.create_entity(entity)

    def get_record(self, image_id: str) -> ImageRecord | None:
        try:
            return record_from_entity(self._table.get_entity(image_id, PARTITION_ROW))
        except ResourceNotFoundError:
            return None

    def enqueue(self, image_id: str) -> None:
        self._queue.send_message(json.dumps({"id": image_id}))

    def _delegation_key(self, now: datetime) -> UserDelegationKey:
        # Cache the key for 1h and refresh 10 min early; one key signs many SAS URLs.
        with self._udk_lock:
            if self._udk is None or now >= self._udk_expiry - timedelta(minutes=10):
                start = now - timedelta(minutes=5)
                expiry = now + timedelta(hours=1)
                self._udk = self._blob_svc.get_user_delegation_key(start, expiry)
                self._udk_expiry = expiry
            return self._udk

    def sign_read_url(self, name: str) -> str:
        now = datetime.now(UTC)
        common: dict[str, Any] = {
            "account_name": self._s.account_name,
            "container_name": self._s.container,
            "blob_name": name,
            "permission": BlobSasPermissions(read=True),
            "start": now - timedelta(minutes=1),  # tolerate small clock skew
            "expiry": now + timedelta(seconds=self._s.sas_ttl_seconds),
        }
        if self._s.auth_mode == "key":
            sas = generate_blob_sas(account_key=self._s.account_key, **common)
        else:
            sas = generate_blob_sas(user_delegation_key=self._delegation_key(now), **common)
        base = self._s.blob_public_endpoint.rstrip("/")
        return f"{base}/{self._s.container}/{name}?{sas}"

    def ping(self) -> None:
        # A cheap authenticated call that only needs the roles the API already has.
        next(iter(self._table.query_entities("PartitionKey eq '__none__'")), None)
