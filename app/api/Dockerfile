# checkov:skip=CKV_DOCKER_2:Kubernetes ignores Docker HEALTHCHECK; liveness/readiness probes are set in the manifests (M3), compose has its own healthcheck
# API image: FastAPI + the built React UI (D-002). Build context = repo root:
#   docker build -f app/api/Dockerfile -t gyazo-api .
# Base images are pinned by tag + digest (Dependabot bumps both); CI scans with Trivy (build.yml).

FROM node:24.22.2-slim@sha256:01d566e8d94d8c619591d78652babfccd3c6992a3dffa9ed5ab39e11cf6c70e9 AS web
WORKDIR /web
COPY app/web/package.json app/web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY app/web/ ./
RUN npm run build

FROM ghcr.io/astral-sh/uv:0.13.10@sha256:a3ea1357342c1a4bf9a0c53a3deb1b55379aefa037338d8113d5771efa01774f AS uv

FROM python:3.13-slim@sha256:7249d5587b78209a006dc4a3b5340678f84ea729239193aa559962cd8c1fce50 AS runtime
# Security: take Debian fixes published since the base digest was built, and drop pip
# (the app runs from the uv venv; pip's vendored urllib3/msgpack/pkg_resources were the
# Trivy HIGH findings). Dependabot's digest bumps make the upgrade a no-op over time.
RUN apt-get update && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip uninstall -y pip
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
