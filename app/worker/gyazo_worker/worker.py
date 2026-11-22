"""Queue worker loop: receive job → process → write thumbnail + metadata → delete job.

Delivery is at-least-once, so handling is idempotent (thumbnail overwrite, entity merge).
Failures:
- invalid image          → mark ``failed`` and delete the job (retrying can't help)
- transient error        → leave the job; it reappears after the visibility timeout
- dequeued MAX_ATTEMPTS+ → poison: mark ``failed`` and delete, so one bad job can't loop forever
"""

from __future__ import annotations

import json
import logging
import os
import signal
import time
from dataclasses import dataclass
from typing import Any, Protocol

from .processor import InvalidImageError, Processor, ThumbnailProcessor

log = logging.getLogger("gyazo_worker")

MAX_ATTEMPTS = 5
PARTITION_ROW = "meta"


def blob_name(image_id: str) -> str:  # must match the API's layout (gyazo_api.images)
    return f"img/{image_id}"


def thumb_blob_name(image_id: str) -> str:
    return f"thumb/{image_id}.webp"


@dataclass
class Job:
    image_id: str
    dequeue_count: int
    raw: Any  # the SDK message, needed to delete it


class Backend(Protocol):
    def receive(self, max_messages: int) -> list[Job]: ...
    def delete(self, job: Job) -> None: ...
    def download(self, name: str) -> bytes: ...
    def upload_thumbnail(self, name: str, data: bytes) -> None: ...
    def update_record(self, image_id: str, fields: dict[str, Any]) -> None: ...


def handle(job: Job, backend: Backend, processor: Processor) -> str:
    """Process one job. Returns the outcome for logs/tests: done | failed | retry."""
    image_id = job.image_id
    try:
        result = processor.process(backend.download(blob_name(image_id)))
    except InvalidImageError as e:
        log.warning("invalid image id=%s: %s", image_id, e)
        backend.update_record(image_id, {"status": "failed", "error": "invalid image"})
        backend.delete(job)
        return "failed"
    except Exception:
        if job.dequeue_count >= MAX_ATTEMPTS:
            log.exception("giving up id=%s after %d attempts", image_id, job.dequeue_count)
            backend.update_record(image_id, {"status": "failed", "error": "processing error"})
            backend.delete(job)
            return "failed"
        log.exception("transient failure id=%s attempt=%d", image_id, job.dequeue_count)
        return "retry"
    backend.upload_thumbnail(thumb_blob_name(image_id), result.thumbnail)
    backend.update_record(
        image_id,
        {
            "status": "ready",
            "width": result.width,
            "height": result.height,
            "format": result.format,
            "thumb_blob": thumb_blob_name(image_id),
        },
    )
    backend.delete(job)
    log.info("processed id=%s %dx%d", image_id, result.width, result.height)
    return "done"


def parse_message(content: str) -> str | None:
    try:
        image_id = json.loads(content)["id"]
    except (ValueError, KeyError, TypeError):
        return None
    return image_id if isinstance(image_id, str) and image_id.isalnum() else None


class AzureBackend:
    def __init__(self) -> None:
        from azure.core.credentials import AzureNamedKeyCredential
        from azure.data.tables import TableServiceClient, UpdateMode
        from azure.storage.blob import BlobServiceClient
        from azure.storage.queue import (
            QueueServiceClient,
            TextBase64DecodePolicy,
            TextBase64EncodePolicy,
        )

        env = os.environ
        account = env["STORAGE_ACCOUNT_NAME"]
        if env.get("STORAGE_AUTH_MODE", "entra") == "key":
            cred: Any = AzureNamedKeyCredential(account, env["STORAGE_ACCOUNT_KEY"])
        else:
            from azure.identity import DefaultAzureCredential

            cred = DefaultAzureCredential()
        blob_ep = env.get("STORAGE_BLOB_ENDPOINT", f"https://{account}.blob.core.windows.net")
        queue_ep = env.get("STORAGE_QUEUE_ENDPOINT", f"https://{account}.queue.core.windows.net")
        table_ep = env.get("STORAGE_TABLE_ENDPOINT", f"https://{account}.table.core.windows.net")
        self._container = BlobServiceClient(blob_ep, credential=cred).get_container_client(
            env.get("STORAGE_CONTAINER", "images")
        )
        # Same encoding as the API producer (D-019).
        self._queue = QueueServiceClient(
            queue_ep,
            credential=cred,
            message_encode_policy=TextBase64EncodePolicy(),
            message_decode_policy=TextBase64DecodePolicy(),
        ).get_queue_client(env.get("STORAGE_QUEUE", "image-jobs"))
        self._table = TableServiceClient(table_ep, credential=cred).get_table_client(
            env.get("STORAGE_TABLE", "images")
        )
        self._merge = UpdateMode.MERGE
        self._visibility = int(env.get("JOB_VISIBILITY_TIMEOUT", "60"))

    def receive(self, max_messages: int) -> list[Job]:
        jobs = []
        for msg in self._queue.receive_messages(
            max_messages=max_messages, visibility_timeout=self._visibility
        ):
            image_id = parse_message(msg.content)
            if image_id is None:
                log.warning("dropping malformed message id=%s", msg.id)
                self._queue.delete_message(msg)
                continue
            jobs.append(Job(image_id=image_id, dequeue_count=msg.dequeue_count or 1, raw=msg))
        return jobs

    def delete(self, job: Job) -> None:
        self._queue.delete_message(job.raw)

    def download(self, name: str) -> bytes:
        return self._container.download_blob(name).readall()

    def upload_thumbnail(self, name: str, data: bytes) -> None:
        from azure.storage.blob import ContentSettings

        self._container.upload_blob(
            name, data, overwrite=True, content_settings=ContentSettings(content_type="image/webp")
        )

    def update_record(self, image_id: str, fields: dict[str, Any]) -> None:
        entity = {"PartitionKey": image_id, "RowKey": PARTITION_ROW, **fields}
        self._table.update_entity(entity, mode=self._merge)


class Stopper:
    """SIGTERM/SIGINT → finish the current job, then exit (Kubernetes graceful shutdown)."""

    def __init__(self) -> None:
        self.stopped = False
        signal.signal(signal.SIGTERM, self._stop)
        signal.signal(signal.SIGINT, self._stop)

    def _stop(self, *_: object) -> None:
        log.info("shutdown requested")
        self.stopped = True


def run(backend: Backend, processor: Processor, stopper: Stopper, idle_sleep: float = 2.0) -> None:
    while not stopper.stopped:
        try:
            jobs = backend.receive(max_messages=8)
        except Exception:
            log.exception("receive failed; backing off")
            time.sleep(idle_sleep * 5)
            continue
        if not jobs:
            time.sleep(idle_sleep)
            continue
        for job in jobs:
            handle(job, backend, processor)
            if stopper.stopped:
                break


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    # The Azure SDK logs every HTTP request/response at INFO; keep only warnings.
    logging.getLogger("azure").setLevel(logging.WARNING)
    run(AzureBackend(), ThumbnailProcessor(), Stopper())


if __name__ == "__main__":
    main()
