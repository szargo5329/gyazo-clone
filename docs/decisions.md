# Decisions log

Format: context → decision → alternatives → why. Status: Proposed / Accepted / Superseded. Entries marked *verify* need a `researcher` check against current docs before implementation.

## D-001 Single-user demo scope — Accepted
- **Context:** Brief excludes login; the app still needs to prevent anonymous uploads to a public endpoint.
- **Decision:** One owner API key for `/upload`; `/i/*` public. Key in Key Vault, mounted via CSI driver.
- **Alternatives:** Entra ID login (feature creep, brief says no); fully open upload (abuse/cost risk).
- **Why:** Minimal auth that still demonstrates secret handling and path-based ingress policy.

## D-002 App stack: FastAPI + React (Vite), static files built into API image — Accepted
- **Alternatives:** Angular (user knows it, heavier), separate frontend service/Static Web Apps (another moving part).
- **Why:** One image, one deployment; frontend is not the point.

## D-003 Metadata in Table Storage, jobs in Storage Queue — Accepted
- **Alternatives:** Cosmos DB (cost/complexity), PostgreSQL Flexible Server (~always-on cost), Service Bus (richer, paid tier, overkill).
- **Why:** Same storage account as Blob → one identity, one RBAC scope, pennies. KEDA has a native Azure Queue scaler.

## D-004 Serve images via short-lived user-delegation SAS redirect — Accepted
- **Alternatives:** Stream through API (bandwidth/CPU on pods); public blob container (no control, guessable listing risk); account-key SAS (requires shared key).
- **Why:** Storage stays private, shared-key disabled, bytes go straight from Blob. User-delegation SAS is signed with an Entra token, revocable.

## D-005 Identity: workload identity for pods, GitHub OIDC → user-assigned managed identity for CI — Accepted
- **Why:** No long-lived secrets anywhere. Mirrors the AWS OIDC pattern from the previous project. Storage `shared_access_key_enabled = false`.
- **Note:** Terraform's azurerm backend and provider use Entra auth (`use_azuread_auth`) accordingly.

## D-006 Terraform state in Azure Storage via separate `bootstrap/` config — Accepted
- **Alternatives:** HCP Terraform (external dependency), local state (not reproducible/CI-usable).
- **Why:** Chicken-and-egg solved explicitly; bootstrap state is local and tiny.

## D-007 AKS networking: Azure CNI Overlay, public API server with authorized IP ranges — Accepted
- **Alternatives:** Kubenet (being retired), CNI flat (IP-hungry), private cluster (needs jumpbox/VPN — cost and friction; revisit with M8 runner).
- **Why:** Modern default, cheap, honest security trade-off documented.

## D-008 Ingress: Gateway API with Envoy Gateway + cert-manager — Accepted (researched 2026-11-20)
- **Context:** Community ingress-nginx retired March 2026. The AKS managed NGINX add-on loses Microsoft security patches in **November 2026**. The AKS App Routing *Gateway API* implementation (`approuting-istio`) is managed and Microsoft's new default. However:
  - It **cannot rate-limit**: the docs list this under limitations.
  - Its TLS needs Key Vault certificates + workload identity + an Azure DNS zone.
  - It runs about 4 always-on pods (istiod ×2 + gateway ×2), which is heavy on 2-vCPU nodes.

  Application Gateway for Containers bills several fixed hourly meters and has no native rate limiting.
- **Decision:** Gateway API (`Gateway` + `HTTPRoute`) implemented by **Envoy Gateway** (Helm, pinned), with TLS from **cert-manager**/Let's Encrypt.
  - Public `/i/*`.
  - `/upload` checks the API key **in the app** (FastAPI), plus a local per-path rate limit via `BackendTrafficPolicy`. No Redis needed.
- **Alternatives:**
  - App Routing Gateway API add-on: the fallback if rate limiting moves to "Later".
  - Traefik.
  - AGC: cost.
  - Managed NGINX: support ends this month.
- **Why:** Gateway API is the current Kubernetes standard (Ingress's successor). Envoy Gateway gives rate limiting and Let's Encrypt with a small footprint. This deliberately departs from the "prefer add-ons" convention for the reasons above.
- **Risks / to verify in M3:**
  - Exact `BackendTrafficPolicy` local-rate-limit YAML.
  - Gateway API CRD ownership: don't enable the AKS managed Gateway API CRDs alongside the chart's.
  - Pin the Envoy Gateway, Gateway API CRD and cert-manager versions together.

## D-009 Observability: kube-prometheus-stack + OTel Collector + Tempo + Loki, self-hosted — Accepted
- **Alternatives:** Azure Managed Prometheus/Grafana + App Insights (less to run, more Azure-specific, cost per GB).
- **Why:** Portable skills, full control for experiments, no per-GB ingest bill. Trade-off: we operate it.

## D-010 Ansible: optional M8 self-hosted GitHub runner VM in the VNet — Accepted (cuttable)
- **Why:** Gives Ansible genuine OS-level work (packages, runner service, hardening) and enables private-network CI later. Run from WSL (Ansible control node doesn't run natively on Windows).

## D-011 DNS / TLS: public IP DNS label + Let's Encrypt HTTP-01 — Accepted with risk (researched 2026-11-20)
- **Decision:** `<label>.centralus.cloudapp.azure.com`.
  - Create the public IP with `domain_name_label` **in Terraform** and point the gateway's LoadBalancer Service at it (`azure-load-balancer-ipv4` + `azure-load-balancer-resource-group` annotations), so the hostname survives cluster rebuilds.
  - cert-manager uses an HTTP-01 challenge through the same Gateway.
- **Risk:** Let's Encrypt allows 50 certs per registered domain per week, shared globally. In 2024 `*.cloudapp.azure.com` users hit shared limits after Public Suffix List changes, and the current status is unconfirmed.
  - Develop against the **staging** issuer, request production once, and keep the cert Secret.
- **Fallback:** buy a cheap domain + Azure DNS zone.
- **Why:** no domain purchase, and fully automated TLS.

## D-012 CI identities: read-only plan identity, separate apply identity — Accepted
- **Context:** The PR workflow runs `terraform plan` with GitHub OIDC on `pull_request`. The workflow and Terraform code come from the PR branch, so anyone able to open a same-repo PR can influence what runs with the Azure token. The federated subject for PRs (`repo:<owner>/gyazo-clone:pull_request`) can't be pinned to a branch. Fork PRs get no OIDC token.
- **Decision:** Two user-assigned managed identities.
  - `id-gyazo-ci-plan`: Reader on the RG plus Storage Blob Data Reader on the state container. Its subject is a GitHub Environment `plan` (`...:environment:plan`). Plan runs with `-lock=false`.
  - `id-gyazo-ci-apply`: write roles. Its subject is pinned to `ref:refs/heads/main`, or a protected `apply` environment with required reviewers.
- **Alternatives:** One Contributor identity for both (simplest; a malicious PR could change infra). `pull_request_target` (runs base-branch code, but checking out PR code with secrets is a known foot-gun).
- **Why:** The worst a PR can do with the plan identity is read. Writes only happen from `main` after review. Found by the reviewer agent on PR 1.

## D-013 Region centralus, nodes Standard_D2s_v6 — Accepted (supersedes eastus2)
- **Context:** The free trial couldn't raise quota. After upgrading to pay-as-you-go: 10 vCPUs per region. DASv5/DSv5/Dv5 are at 0, and DASv5 requests are declined in eastus2 ("high demand"). Dsv6 has 10, but Dsv6 sizes are `NotAvailableForSubscription` in eastus2 and westus2.
- **Decision:** `centralus` with `Standard_D2s_v6` (2 vCPU, 8 GB).
- **Alternatives:** eastus/westus3 (also available, no advantage); a support ticket for DASv5 in eastus2 (days of delay); a single 4-vCPU node on the trial (no upgrade surge, no room to scale).
- **Why:** Available today with no ticket. 10 vCPUs covers 2 nodes + upgrade surge + KEDA burst. Latency is irrelevant for a demo.

## D-014 No dedicated security agent — Accepted
- **Context:** Security matters across every milestone (IAM, network exposure, secrets, supply chain).
- **Decision:** Security stays the **first** priority of the `reviewer` agent, backed by deterministic tools (Checkov, gitleaks, actionlint, later Trivy) and the human plan gate. Threat model lives in `docs/security.md`.
- **Alternatives:** A separate `security-reviewer` agent on every PR.
- **Why:** Almost every change in this repo *is* security-relevant (IAM, network, identity), so a second reviewer would read the same diff with the same model and mostly duplicate findings at double the cost. Scanners give the independent check. Revisit if the reviewer starts missing security issues, or reviews get long enough that security gets crowded out. The retro is where that gets decided.
- **Update (2026-11-21):** GitHub's OIDC `sub` claim now embeds immutable IDs: `repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:<env>`. The first CI plan failed with AADSTS700213 until the federated credentials matched. This is stronger than name-based subjects, because a deleted and re-created repo with the same name gets a new ID.
