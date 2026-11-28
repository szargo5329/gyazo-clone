# checkov:skip=CKV_DOCKER_2:Kubernetes ignores Docker HEALTHCHECK; liveness/readiness probes are set in the manifests (M3), compose has its own healthcheck
# API image: FastAPI + the built React UI (D-002). Build context = repo root:
#   docker build -f app/api/Dockerfile -t gyazo-api .
# Base images are pinned by tag + digest (Dependabot bumps both); CI scans with Trivy (build.yml).

FROM node:24.16.0-slim@sha256:2c87ef9bd3c6a3bd4b472b4bec2ce9d16354b0c574f736c476489d09f560a203 AS web
WORKDIR /web
COPY app/web/package.json app/web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY app/web/ ./
RUN npm run build

FROM ghcr.io/astral-sh/uv:0.13.3@sha256:bee0a2a458fd956c5df7b8b4c5fed2257b0af34866e3da7b51db0be3acb375d1 AS uv

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
# --proxy-headers: take the client address and scheme from X-Forwarded-For/-Proto, but only
# when the TCP peer is in --forwarded-allow-ips. 10.244.0.0/16 is the AKS pod CIDR
# (infra/terraform/modules/aks, var.pod_cidr), where the Envoy proxy pods connect from
# (D-028). Every other peer's forwarded headers are ignored: under compose the peer is a
# Docker bridge address, so locally the headers are simply not trusted, which is harmless.
# uvicorn 0.54 accepts comma-separated IPs and CIDRs here.
CMD ["uvicorn", "gyazo_api.main:app_factory", "--factory", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "10.244.0.0/16"]
