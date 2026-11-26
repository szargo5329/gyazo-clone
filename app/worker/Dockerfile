# checkov:skip=CKV_DOCKER_2:Kubernetes ignores Docker HEALTHCHECK; liveness/readiness probes are set in the manifests (M3), compose has its own healthcheck
# Worker image. Build context = repo root:
#   docker build -f app/worker/Dockerfile -t gyazo-worker .

FROM ghcr.io/astral-sh/uv:0.13.3@sha256:bee0a2a458fd956c5df7b8b4c5fed2257b0af34866e3da7b51db0be3acb375d1 AS uv

FROM python:3.13-slim@sha256:7249d5587b78209a006dc4a3b5340678f84ea729239193aa559962cd8c1fce50
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
RUN uv sync --frozen --no-dev --package gyazo-worker --no-install-workspace
COPY app/worker/gyazo_worker app/worker/gyazo_worker
RUN uv sync --frozen --no-dev --package gyazo-worker
RUN useradd --uid 10001 --no-create-home app
USER 10001
CMD ["python", "-m", "gyazo_worker.worker"]
