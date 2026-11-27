# Spec — Gyazo-style image platform on Azure

## Goal
Demonstrate platform engineering on Azure, integrated with AI: reproducible infra (Terraform), GitOps delivery, OIDC CI, built-in observability with an SLO, documented failure experiments, and an AI screenshot overview run like a production dependency (evals in CI, privacy, cost and failure handling). The product is a vehicle; the platform and the way the AI step is operated are the point.

## Product scope (single-user demo)
- **Upload:** `POST /upload` (multipart) with the owner API key (`X-API-Key`). Clients: web UI (paste / drag-drop / file picker) and ShareX custom uploader. Same endpoint.
- **Types:** PNG, JPEG, GIF, WebP. Size cap (default 10 MB). Validated by magic bytes, not just extension.
- **Link:** returns `https://<host>/i/<id>`; `id` = 22 chars base62 (~128 bits random), unguessable.
- **View:** `GET /i/<id>` is public; the API redirects (302) to a user-delegation SAS URL for that blob, valid ≤ 5 minutes. Image bytes never stream through the API.
- **Processing:** async worker generates a thumbnail + reads metadata; row status `pending → ready | failed`. The page shows the image regardless; thumbnail/description are optional enrichments.
- **AI overview (M-AI):** the worker asks a vision model for a short overview of the screenshot (app, visible text, any error message). It is a separate step with its own status, so a failed or slow model call never blocks the upload or the view. Design requirements: "AI overview" below.
- **Owner key:** stored in Key Vault, mounted via the Secrets Store CSI driver. Web UI keeps it in `localStorage` → requires a strict CSP (no inline scripts, no third-party script origins).
- **Abuse limits:** KEDA `maxReplicaCount` caps worker throughput; ingress rate limit on `/upload`.

## Non-goals
User accounts/login, multi-tenant, social features, editing tools, streaks/gamification, video (MP4), custom domains per user, HA/multi-region, backups beyond storage soft-delete.

## AI overview (M-AI) — design requirements
Core scope (owner decision, 2026-11-25): the project shows cloud infrastructure integrated with AI, so the overview is a milestone, not a stretch. Model, hosting and region are chosen at M-AI start with the researcher and recorded in `docs/decisions.md`. Preference: a model hosted in our own Azure subscription, called with workload identity (no API keys).
- **Evals (required, part of the milestone):**
  - **Labeled set:** 30–50 screenshots in the repo, each with the facts its overview must contain: app, key visible text, error message. Include hard cases: blurry or tiny text, dark mode, non-English, and screenshots with sensitive content (synthetic only, never real secrets).
  - **Automatic scoring:** required facts present; nothing claimed that isn't in the image (hallucination check); length limit; sensitive values not repeated back.
  - **Model-as-judge:** only for the fuzzy checks, with a sample of its grades spot-checked by hand and recorded.
  - **Tracking:** pass rate, cost per image and latency, recorded per run. The suite runs in CI on any change to the prompt, model or processor, and a drop below the threshold fails the build.
- **Privacy:** screenshots often contain passwords, emails and private chats. Before the first real call, decide and document:
  - whether the model provider keeps or trains on inputs
  - whether overviews are generated from the stored blob or in memory
  - how long images and overviews are kept (see the retention gap in M2)
  - whether private endpoints are worth their cost here
- **Cost and abuse:**
  - Cache overviews by image content hash, so a re-upload isn't processed twice.
  - Cap output tokens.
  - Reuse the upload rate limit and the KEDA `maxReplicaCount` cap.
  - Emit cost per image as a metric.
  - Track spend against the $50 budget (D-017). Eval runs call the model too: cap each CI run, by sample size or a cost ceiling, and run the full set only when the prompt, model or processor changes.
  - CI needs model access without a stored key (GitHub OIDC). Neither CI identity has a model role today, and adding one is an IAM change that needs owner approval.
- **Security:**
  - Render the overview as plain text, never HTML: model output is untrusted, and the page keeps the owner key in `localStorage`, so HTML output would be a stored-XSS path.
  - Treat text inside screenshots as untrusted model input (prompt injection). The model has no tools or credentials, so the worst case is a bad overview, never an action.
- **Failure handling:**
  - Timeouts and bounded retries on the model call.
  - Overview status `pending → ready | failed`, separate from the thumbnail.
  - The page renders without an overview.
  - A failure experiment: the model endpoint is unavailable, and uploads and views still succeed.

## Later (only after M6, each optional)
- Semantic search / RAG / agents over overviews (one model call per image is not RAG).
- Private endpoints for storage/Key Vault (cost vs. security trade-off, see decisions). The M-AI privacy decision may pull this forward.
- CDN (Azure Front Door, the CloudFront equivalent): skipped for now. Images are served through per-view SAS links that expire within 5 minutes, which a shared cache works against. The monthly base fee would also take most of the $50 budget for a one-user demo. Worth it at real scale with public or long-lived content.

## Success criteria (= definition of done)
1. Clean subscription → running system using `infra/bootstrap`, `infra/terraform` and documented steps.
2. Delivered via ArgoCD; CI uses GitHub OIDC (no long-lived Azure secrets in GitHub).
3. Grafana dashboards, alerts, and ≥1 SLO (availability of `GET /i/*`, 99.5% over 7d, multi-window burn-rate alert) working against real traffic.
4. Five failure experiments run and written up (hypothesis, method, dashboards, recovery, lessons): 1 kill pod (M3); 2 break storage access (remove role assignment) and 3 saturate queue (M4); 4 bad deploy + rollback (M6); 5 model endpoint down (M-AI). Numbers are IDs from when each was planned, so 5 runs before 4.
5. README: architecture diagram, cost notes, teardown steps, decisions log.
6. AI overview live, with its eval suite gating CI (pass rate, cost per image and latency tracked).
7. Torn down after verification; teardown verified (no billable resources remain).

## Milestones
| # | Milestone | Effort | Verification |
|---|---|---|---|
| M0 | Workflow: CLAUDE.md, agents, hooks, CI skeleton, repo on GitHub | 0.5 d | Hooks fire; CI green on a test PR |
| M1 | Azure foundation: bootstrap state, RG, VNet, ACR, storage, Key Vault, identities, GitHub OIDC; budget alert | 1–2 d | `terraform plan` reviewed → apply (approved); CI `plan` runs via OIDC |
| M2 | Local app: API + web + worker, tests, Azurite, ShareX against localhost | 1–2 d | pytest/ruff/vitest green; ShareX upload → link works locally |
| M3 | **First vertical slice on AKS:** raw manifests, ingress, workload identity, metrics + 1 Grafana dashboard; experiment 1 (kill pod) | 2 d | Upload/view from internet; dashboard shows RED metrics; experiment write-up |
| M4 | Queue + KEDA worker, OTel traces (Tempo), SLO + alerts; experiments 2–3 | 2 d | Trace spans API→queue→worker; burn-rate alert fires in experiment |
| M-AI | AI screenshot overview: vision model (preferably keyless via workload identity; an API key would live in Key Vault and needs its own decision), eval suite in CI, privacy/retention decisions, cache + cost metric, graceful failure (see "AI overview"). After M4 because it needs the queue worker and traces. | 2–3 d | Eval suite green in CI with pass rate, cost/image and latency recorded; a prompt change that drops below threshold fails the build; model-down experiment (5): upload/view still work |
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
- Repo settings (not in Terraform; checked with `gh api` on 2026-11-21): `apply` environment requires reviewer szargo5329 and protected branches only (self-approval allowed: a solo-owner gate, not two-person review); `main` requires checks detect, actionlint, checkov, gitleaks, terraform fmt/validate/tflint and terraform plan (the two terraform checks were added on 2026-11-21 after review; a skipped job still satisfies a required check; now 9, see M2), linear history, no force push or deletion.
- Resources were created by the human-approved local applies (M1 PR #3; the table migration in D-015). The CI runs show convergence, not creation.

Known gaps (each has an owner and a trigger):

| Gap | Owner | Close by |
|---|---|---|
| ~~ABAC negative test: acting as ci-apply, a role-assignment write targeting ci-apply itself should fail with 403 `AuthorizationFailed`.~~ Closed 2026-11-25. **Verified:** run 45751807956 (`abac-check.yml`, `workflow_dispatch` on `main` 35bc0e4, owner approved the `apply` gate), after the bootstrap condition change. 1 self-grant AcrPull → denied (ABAC condition); 2 non-allowlisted Reader → denied (ABAC condition); 3 control AcrPull → api → allowed, then deleted. `az role assignment list` afterwards shows no AcrPull or Reader on the api identity. | owner runs it (IAM); orchestrator prepares it | Closed before the first M3 apply |
| Destroy guard: neither the blocking path nor the `allow_destroy` override has run live; only the pass-through path has. | orchestrator | Before M9 teardown, at the latest |
| ~~Budget alert at 50% only; a 90% actual-spend alert is pending (D-017).~~ Closed 2026-11-24: owner added the 90% actual alert to the $50 budget in the portal (owner-reported, not agent-verified). | owner (portal) | Closed before M3 |
| ci-apply write path unproven: every CI apply so far was a no-op, so no write has run as ci-apply. | owner watches the first apply | First M3 apply with real changes |
| ~~`setup-uv` / `setup-node` (bumped in #4) not yet exercised: python/web CI jobs skip until `app/` exists.~~ Closed: python and web jobs ran green on PR #9 (head fe50d7f). | orchestrator | Closed in M2 |

### M2 — complete (2026-11-23)
Code merged in PR #9 (6e3ea54); diagrams in PR #10 (20d7957).

Evidence:
- **Acceptance (verified, owner, 2026-11-23):** ShareX 22.4 with `app/sharex/gyazo-clone-local.sxcu` → `POST /upload` 201 → link copied → `GET /i/m5XeV3O06juIgQXPC7TfSw` 302 → image shown in the browser. API log shows both requests; `/api/images/<id>` reports `ready`, 158×55, with a thumbnail. ShareX needed "After capture tasks → Upload image to host" turned on (now in `docs/local-dev.md`).
- **Verified (CI):** PR #9 head fe50d7f, all 9 checks green, including `e2e (compose + smoke)` (15/15).
- **Verified (`gh api` required_status_checks, 2026-11-23):** all 9 are required on `main`. The three M2 jobs were made required: python lint/test and web lint/test/build because they are the app's only unit gates, and e2e because it is the only check that runs the services together.
- **Verified (local + CI):** `uv run pytest -q`: 82 passed (API routes, auth, the early upload guard, validation, CSP headers, SAS shape, the Entra signer with a stubbed key service: caching, refresh, `skoid`/`sktid`, TTL; worker processing, crash/poison/OOM/deleted-record paths, the 40 MP bomb cap, queue encoding on both clients). `npm test`: 12 passed.
- **Verified (local + CI):** `scripts/smoke.py` against `docker compose` (Azurite + API + worker): 15/15 checks. Bad key → 401, non-image → 415, upload → 201, worker → ready with a 320×160 WebP thumbnail, `/i/<id>` → 302 to a SAS returning identical bytes, tampered SAS → 403, unknown id → 404, strict CSP.
- **Verified (local):** real browser (desktop app pane): paste → link → thumbnail, with no console or CSP errors. Screenshots: `docs/diagrams/ui-m2-*.jpg`.
- **Verified (local + CI build):** `vite build` output has no inline scripts or styles (`scripts/check-csp.mjs`, negative-tested).

Known gaps:

| Gap | Owner | Close by |
|---|---|---|
| Entra signing path (user-delegation key) untested: Azurite can't issue one (D-019). | orchestrator | First AKS deploy (M3) |
| Ingress rate limit on `/upload` (spec) not in M2; it belongs to the gateway. | orchestrator | M3 (Envoy Gateway) |
| ~~Docker base images pinned by tag, not digest; no image scan yet.~~ Fixed in code (D-026): tag@digest pins, Trivy gate in `build.yml`. **Verified locally** (both images scan clean); closes when the first CI run is green. | orchestrator | M3 |
| Trivy gates on fixable HIGH/CRITICAL only; no periodic full report of unfixed CVEs (D-026). | orchestrator | M4 (with alerts) |
| Nightly AKS stop (D-025) fails silently if GitHub disables scheduled workflows after 60 days of repo inactivity. Backstop: the budget alerts (D-017). | owner | M9 (or when the repo goes quiet) |
| Only one registry may exist in `rg-gyazo-<env>` (AcrPush is RG-scoped, D-024); not enforced in code. | orchestrator | M3 close (tighten scope or add a check) |
| Upload isn't atomic: if the table insert or enqueue fails after the blob write, an orphan blob (or a `pending` record with no job) is left. | orchestrator | M4 (janitor/expiry with the queue work) |
| The early body-size check trusts `Content-Length`; a lying client is still cut off at cap+1 bytes in the route, but Starlette may spool up to the real body. | orchestrator | M3 (gateway request-size limit) |
| No alerting on stuck jobs: a poison job retried about 2,300 times unnoticed (see lesson). Need an alert on queue message age / dequeue count. | orchestrator | M4 (SLO + alerts) |
| No image retention policy: images are kept until teardown (storage soft-delete only). Screenshots often hold secrets, so decide how long images (and later overviews) live and enforce it (lifecycle rule or janitor). | orchestrator proposes, owner decides | M4 (janitor), and before M-AI stores any overview |
| Egress allows TCP 443 to any host (D-027); no FQDN-level restriction. Exfiltration path if a pod is compromised. | orchestrator proposes, owner decides (cost) | M4 threat review (Cilium FQDN policy or firewall) |
| Cilium CIDR semantics untested: confirm the 443 rule does not allow in-cluster traffic (curl from the api pod to another pod/node IP on 443 must fail). | orchestrator | First M3 deploy |
| Image digests in `kustomization.yaml` are hand-pinned; confirm they exist in ACR (`az acr repository show`) and automate pinning. | orchestrator | Confirm at first apply; automate in M6 (ArgoCD) |
| No `ephemeral-storage` requests/limits on containers (emptyDirs have `sizeLimit` only). | orchestrator | M5 (Helm chart) |
| Label `app.kubernetes.io/managed-by: kustomize` becomes wrong when Helm takes over. | orchestrator | M5 |
| Ingress to api admits every pod in `envoy-gateway-system`, not only the proxy pods. | orchestrator | When Envoy Gateway is installed (M3) |

Lesson: the local compose stack had been running images built before the reviewer fixes landed, so a stale test job (fake id, no record) retried about 2,300 times over roughly a day and a half on the old worker. **Verified (compose log, 2026-11-23):** after `docker compose up -d --build`, the worker on `main` logged "no longer exists; dropping job" on the first pass and did not see the job again past the 60 s visibility window (the deleted-record path from D-020). Local stacks need a rebuild after pulling; `docs/local-dev.md` now says so.

### M3 — in progress
Evidence so far:
- **Verified (agent-run, owner-approved local applies, 2026-11-25):** bootstrap IAM from #14 and #16.
  - **First apply** (saved plan, 2 add / 1 change): the condition change and ci-plan's grant succeeded; the owner's grant failed (see lesson).
  - **Second apply** (saved plan from 35bc0e4, 1 add): succeeded. This was approved separately.
  - **`az role assignment list -g rg-gyazo-dev`** (same day) shows:
    - RBAC Administrator for ci-apply. The condition lists Network Contributor (`4d97b98b…`) in the `@Request` set under `roleAssignments/write` and in the `@Resource` set under `roleAssignments/delete`.
    - AKS Cluster User Role for ci-plan.
    - AKS RBAC Cluster Admin for the owner.
  - **Not yet shown:** that there is no drift. Bootstrap has no CI, so a clean re-plan is the drift check, and it hasn't been run.

Lesson (agent-observed from the apply output, 2026-11-25): the first bootstrap apply only partly succeeded.
- Two changes applied. The third was rejected with `400 RoleAssignmentCannotContainHtmlTags` because its description contained `rg-<env>`.
- That text is checked by Azure's API at create time, not by Terraform: `terraform plan`, validate, tflint and checkov all passed it.
- The fix (#16) was a separate reviewed PR, and the re-plan (1 to add) was approved again by the owner rather than reusing the first approval.
- Rule: no angle brackets in strings Azure receives (descriptions, tags). Comments and Terraform variable descriptions are fine.
