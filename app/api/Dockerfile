# checkov:skip=CKV_DOCKER_2:Kubernetes ignores Docker HEALTHCHECK; liveness/readiness probes are set in the manifests (M3), compose has its own healthcheck
# API image: FastAPI + the built React UI (D-002). Build context = repo root:
#   docker build -f app/api/Dockerfile -t gyazo-api .
# Base images are pinned by tag here; M3 pins digests and adds image scanning (security.md).

FROM node:24.16.0-slim AS web
WORKDIR /web
COPY app/web/package.json app/web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY app/web/ ./
RUN npm run build

FROM ghcr.io/astral-sh/uv:0.13.3 AS uv

FROM python:3.13-slim AS runtime
COPY --from=uv /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never \
    PYTHONUNBUFFERED=1 PATH="/app/.venv/bin:$PATH"
WORKDIR /app
COPY pyproject.toml uv.lock ./
COPY app/api/pyproject.toml app/api/pyproject.toml
COPY app/worker/pyproject.toml app/worker/pyproject.toml
RUN uv sync --frozen --no-dev --package gyazo-api --no-install-workspace
COPY app/api/gyazo_api app/api/gyazo_api
RUN uv sync --frozen --no-dev --package gyazo-api
COPY --from=web /web/dist /app/static
ENV STATIC_DIR=/app/static
# Non-root, numeric UID so Kubernetes runAsNonRoot can verify it.
RUN useradd --uid 10001 --no-create-home app
USER 10001
EXPOSE 8000
CMD ["uvicorn", "gyazo_api.main:app_factory", "--factory", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
