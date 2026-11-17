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
