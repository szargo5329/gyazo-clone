# checkov:skip=CKV_DOCKER_2:Kubernetes ignores Docker HEALTHCHECK; liveness/readiness probes are set in the manifests (M3), compose has its own healthcheck
# Worker image. Build context = repo root:
#   docker build -f app/worker/Dockerfile -t gyazo-worker .

FROM ghcr.io/astral-sh/uv:0.13.3 AS uv

FROM python:3.13-slim
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
