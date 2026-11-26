# Local development (M2)

Everything runs on your machine: Azurite emulates Blob/Queue/Table, so no Azure account or cost.

```
browser / ShareX ──► API :8000 ──► Azurite blob  img/<id>          (image bytes)
                        │     └──► Azurite table images/<id>       (status, size, dims)
                        └────────► Azurite queue image-jobs        ({"id": ...})
                                          │
                           worker ◄───────┘  → thumb/<id>.webp + entity merge (status=ready)

GET /i/<id> ──► API 302 ──► http://localhost:10000/... ?<read-only SAS, ≤5 min>
```

## Run the whole stack

```powershell
python -c "import secrets; print('OWNER_API_KEY=' + secrets.token_urlsafe(32))" > .env
```

```powershell
docker compose up --build
```

After pulling new code, rebuild (`docker compose up -d --build`): a running stack keeps the old images, so it won't have the latest fixes.

Open http://localhost:8000, paste the key from `.env` into **API key** (it's kept in this browser's localStorage), then paste a screenshot (Ctrl+V), drop a file or click to choose one.

End-to-end check (the same one CI runs):

```powershell
uv run --all-packages python scripts/smoke.py
```

(`OWNER_API_KEY` must be set in that shell, e.g. from `.env`.)

## ShareX

1. Open `app/sharex/gyazo-clone-local.sxcu` in a text editor and replace `PASTE_YOUR_OWNER_API_KEY_HERE` with your key. Don't commit that edit.
2. Double-click the file. ShareX imports it as a custom uploader.
3. ShareX → Destinations → Image uploader → Custom image uploader.
4. ShareX → After capture tasks → tick **Upload image to host**, and After upload tasks → **Copy URL to clipboard**. A fresh install may only save captures locally, and then nothing reaches the API (check `docker compose logs api` for `POST /upload`).

Screenshots now upload, and the `/i/<id>` link is copied to your clipboard. Then hide your edit from git so it can't be committed by accident (`git add -A`, `git commit -a`):

```powershell
git update-index --skip-worktree app/sharex/gyazo-clone-local.sxcu
```

Undo with `--no-skip-worktree` before pulling a change to that file.

## Tests and lint

```powershell
uv run ruff check . ; uv run ruff format --check . ; uv run pytest -q
```

```powershell
npm --prefix app/web run lint ; npm --prefix app/web test ; npm --prefix app/web run build
```

`npm run build` also runs `scripts/check-csp.mjs`, which fails the build if `index.html` has anything the strict CSP would block.

## UI dev with hot reload

Run the stack (or just Azurite + API), then `npm --prefix app/web run dev`. Vite proxies `/upload`, `/i` and `/api` to `:8000`.

## How local differs from Azure

| | Local (compose) | Azure (M3+) |
|---|---|---|
| Storage auth | `STORAGE_AUTH_MODE=key`, Azurite's public dev key | `entra`: workload identity, no keys |
| SAS | signed with the account key | signed with a user-delegation key (D-019) |
| Container/queue/table | created by the API at startup (`ENSURE_RESOURCES=true`) | created by Terraform; the API has no rights to create them |
| Owner key | `.env` → env var | Key Vault → CSI-mounted file (`OWNER_API_KEY_FILE`) |
