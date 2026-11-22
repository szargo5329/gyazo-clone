# Spec — Gyazo-style image platform on Azure

## Goal
Demonstrate platform engineering on Azure: reproducible infra (Terraform), GitOps delivery, OIDC CI, built-in observability with an SLO, and documented failure experiments. The product is a vehicle, not the point.

## Product scope (single-user demo)
- **Upload:** `POST /upload` (multipart) with the owner API key (`X-API-Key`). Clients: web UI (paste / drag-drop / file picker) and ShareX custom uploader. Same endpoint.
- **Types:** PNG, JPEG, GIF, WebP. Size cap (default 10 MB). Validated by magic bytes, not just extension.
- **Link:** returns `https://<host>/i/<id>`; `id` = 22 chars base62 (~128 bits random), unguessable.
- **View:** `GET /i/<id>` is public; the API redirects (302) to a user-delegation SAS URL for that blob, valid ≤ 5 minutes. Image bytes never stream through the API.
- **Processing:** async worker generates a thumbnail + reads metadata; row status `pending → ready | failed`. The page shows the image regardless; thumbnail/description are optional enrichments.
- **Owner key:** stored in Key Vault, mounted via the Secrets Store CSI driver. Web UI keeps it in `localStorage` → requires a strict CSP (no inline scripts, no third-party script origins).
- **Abuse limits:** KEDA `maxReplicaCount` caps worker throughput; ingress rate limit on `/upload`.

## Non-goals
User accounts/login, multi-tenant, social features, editing tools, streaks/gamification, video (MP4), custom domains per user, HA/multi-region, backups beyond storage soft-delete.

## Later (only after M6, each optional)
- **M-AI:** worker processor calls a vision model for a description/alt text. Privacy note: screenshots leave our boundary — opt-in, documented. One model call ≠ RAG; semantic search / RAG / agents are separate stretches.
- Private endpoints for storage/Key Vault (cost vs. security trade-off, see decisions).

## Success criteria (= definition of done)
1. Clean subscription → running system using `infra/bootstrap`, `infra/terraform` and documented steps.
2. Delivered via ArgoCD; CI uses GitHub OIDC (no long-lived Azure secrets in GitHub).
3. Grafana dashboards, alerts, and ≥1 SLO (availability of `GET /i/*`, 99.5% over 7d, multi-window burn-rate alert) working against real traffic.
4. Four failure experiments run and written up (hypothesis, method, dashboards, recovery, lessons): kill pod; break storage access (remove role assignment); saturate queue; bad deploy + rollback.
5. README: architecture diagram, cost notes, teardown steps, decisions log.
6. Torn down after verification; teardown verified (no billable resources remain).

## Milestones
| # | Milestone | Effort | Verification |
|---|---|---|---|
| M0 | Workflow: CLAUDE.md, agents, hooks, CI skeleton, repo on GitHub | 0.5 d | Hooks fire; CI green on a test PR |
| M1 | Azure foundation: bootstrap state, RG, VNet, ACR, storage, Key Vault, identities, GitHub OIDC; budget alert | 1–2 d | `terraform plan` reviewed → apply (approved); CI `plan` runs via OIDC |
| M2 | Local app: API + web + worker, tests, Azurite, ShareX against localhost | 1–2 d | pytest/ruff/vitest green; ShareX upload → link works locally |
| M3 | **First vertical slice on AKS:** raw manifests, ingress, workload identity, metrics + 1 Grafana dashboard; experiment 1 (kill pod) | 2 d | Upload/view from internet; dashboard shows RED metrics; experiment write-up |
| M4 | Queue + KEDA worker, OTel traces (Tempo), SLO + alerts; experiments 2–3 | 2 d | Trace spans API→queue→worker; burn-rate alert fires in experiment |
| M5 | Helm chart replaces manifests | 1 d | `helm lint`/template diff; redeploy no downtime |
| M6 | ArgoCD GitOps; CI bumps image tag; experiment 4 (bad deploy + rollback) | 1–2 d | Git commit → synced deploy; rollback documented |
| M7 | Logs (Loki) correlated with traces | 0.5–1 d | Log → trace link in Grafana |
| M8 | *(optional)* Ansible-configured self-hosted runner VM in VNet | 1 d | Playbook idempotent (2nd run = 0 changes); runner picks up a job |
| M9 | README, write-ups, cost notes, teardown | 1 d | Fresh-read review; `az resource list` empty after destroy |

Cost control: AKS 1 small system node pool (+ autoscaler min 1), stop cluster (`az aks stop`) when not working, budget alert, teardown at the end.

## Milestone status

### M1 — complete with gaps (2026-11-21)
Evidence:
- No-op apply from `main` via CI (run 44968065880, manual `workflow_dispatch` on `main`): plan job, then the apply job behind the `apply` environment's required-reviewer gate. 0 added, 0 changed, 0 destroyed. The plan artifact's SHA-256 digest matched at upload and download.
- CI `plan` via OIDC (PR run 44967945871), in the `plan` environment, whose `AZURE_CLIENT_ID` is the read-only `id-gyazo-ci-plan` (pr.yml).
- Repo settings (not in Terraform; checked with `gh api` on 2026-11-21): `apply` environment requires reviewer szargo5329 and protected branches only (self-approval allowed: a solo-owner gate, not two-person review); `main` requires checks detect, actionlint, checkov, gitleaks, terraform fmt/validate/tflint and terraform plan (the two terraform checks were added on 2026-11-21 after review; a skipped job still satisfies a required check), linear history, no force push or deletion.
- Resources were created by the human-approved local applies (M1 PR #3; the table migration in D-015). The CI runs show convergence, not creation.

Known gaps (each has an owner and a trigger):

| Gap | Owner | Close by |
|---|---|---|
| ABAC negative test: acting as ci-apply, a role-assignment write targeting ci-apply itself should fail with 403 `AuthorizationFailed`. Design-verified only (security.md, "CI escalates"). | owner runs it (IAM); orchestrator prepares it | Before the first M3 apply that creates role assignments |
| Destroy guard: neither the blocking path nor the `allow_destroy` override has run live; only the pass-through path has. | orchestrator | Before M9 teardown, at the latest |
| Budget alert at 50% only; a 90% actual-spend alert is pending (D-017). Created by the owner, not agent-verified. | owner (portal) | Before M3 creates AKS |
| ci-apply write path unproven: every CI apply so far was a no-op, so no write has run as ci-apply. | owner watches the first apply | First M3 apply with real changes |
| `setup-uv` / `setup-node` (bumped in #4) not yet exercised: python/web CI jobs skip until `app/` exists. | orchestrator | First M2 PR |

### M2 — in review (2026-11-21)
Evidence (verified locally; CI evidence comes with the PR):
- `uv run pytest -q`: 81 passed (API routes, auth, the early upload guard, validation, CSP headers, SAS shape, the Entra signer with a stubbed key service: caching, refresh, `skoid`/`sktid`, TTL; worker processing, crash/poison/OOM paths, the 40 MP bomb cap, queue encoding on both clients). `npm test`: 12 passed.
- `scripts/smoke.py` against `docker compose` (Azurite + API + worker): 15/15 checks. Bad key → 401, non-image → 415, upload → 201, worker → ready with a 320×160 WebP thumbnail, `/i/<id>` → 302 to a SAS returning identical bytes, tampered SAS → 403, unknown id → 404, strict CSP.
- Real browser (desktop app pane): paste → link → thumbnail, with no console or CSP errors. Screenshots: `docs/diagrams/ui-m2-*.jpg`.
- `vite build` output has no inline scripts or styles (`scripts/check-csp.mjs`, negative-tested).

Known gaps:

| Gap | Owner | Close by |
|---|---|---|
| Entra signing path (user-delegation key) untested: Azurite can't issue one (D-019). | orchestrator | First AKS deploy (M3) |
| Ingress rate limit on `/upload` (spec) not in M2; it belongs to the gateway. | orchestrator | M3 (Envoy Gateway) |
| Docker base images pinned by tag, not digest; no image scan yet. | orchestrator | M3 |
| Upload isn't atomic: if the table insert or enqueue fails after the blob write, an orphan blob (or a `pending` record with no job) is left. | orchestrator | M4 (janitor/expiry with the queue work) |
| The early body-size check trusts `Content-Length`; a lying client is still cut off at cap+1 bytes in the route, but Starlette may spool up to the real body. | orchestrator | M3 (gateway request-size limit) |
| **Acceptance "ShareX upload → link works locally" not yet met.** Everything else in the M2 row is. | owner runs it once (see local-dev.md) | Before merging M2 is called done |

