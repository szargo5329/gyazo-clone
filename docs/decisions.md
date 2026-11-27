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
  - Create the public IP with `domain_name_label` **in Terraform** and point the gateway's LoadBalancer Service at it (`azure-pip-name` + `azure-load-balancer-resource-group` annotations; by name rather than `azure-load-balancer-ipv4`, so the control plane's PIP-scoped grant is enough, see D-021), so the hostname survives cluster rebuilds.
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
- **Update (2026-11-21):** GitHub's OIDC `sub` claim now embeds immutable IDs: `repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:<env>`. The first CI plan failed with AADSTS700213 until the federated credentials matched. This is stronger than name-based subjects, because a deleted and re-created repo with the same name gets a new ID.

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

## D-015 Storage table managed via azapi (ARM) instead of azurerm — Accepted
- **Context:** `azurerm_storage_table` (v5) reads table ACLs through the **data plane** (`Exists`/`GetACLs`). The CI plan identity is Reader-only by design (D-012), so `terraform plan` failed with a 403. The researcher confirmed in the provider source that container and queue reads go through ARM only. The table holds image IDs, and an ID is a capability to view an image, so data-plane read on it means reading every image.
- **Decision:** `azapi_resource` of type `Microsoft.Storage/storageAccounts/tableServices/tables` (an ARM GET, which Reader covers). Migrated with root-module `removed { destroy = false }` + `import`, because child-module imports need Terraform 1.16 and we pin 1.15.8. The ARM ID is unchanged, so the existing role assignments are untouched. The migration blocks were applied on 2026-11-21 and deleted in the follow-up PR (`infra/m1-followups`).
- **Alternatives:**
  - Give ci-plan Storage Table Data Reader: lets PR-triggered code read every image ID.
  - `terraform state rm` + `import`: imperative, not visible in a reviewed plan.
  - Create the table at app startup: drift, and the app would need account-level rights.
- **Why:** keeps the plan identity unable to read app data. The cost is one extra provider (azapi, Microsoft's ARM provider).

## D-016 Destroy/replace guard in CI — Accepted
- **Context:** After the table migration, the reviewer asked that safety not depend on a human spotting a destroy in a plan summary.
- **Decision:**
  - `apply.yml` fails the plan job if the saved plan deletes or replaces anything, so the Approve button never appears.
  - The only way through is a manual `workflow_dispatch` run with the `allow_destroy: true` input, for deliberate teardown.
  - `pr.yml` only warns, because a PR may legitimately propose a destroy, and the human reviews it.
  - Detection uses `terraform show -json` + `jq` on `change.actions` containing `delete`, which covers both delete and replace.
- **Alternatives:**
  - A repo variable to allow destroys: it's persistent and easy to forget to turn off.
  - Treating any manual run as allowed: too easy.
  - Rely on human review only: humans miss things in long plans.
- **Trade-off:** Checkov's SLSA rule CKV_GHA_7 forbids `workflow_dispatch` inputs, so it's skipped inline with a reason. The input never reaches Terraform; it only unblocks the guard.

## D-017 Cost budget created manually, outside Terraform — Accepted
- **Context:** The project runs for about a week, then is torn down. A spend alarm must exist before any billable compute (AKS, M3) is created.
- **Decision:** A $50/month budget with an email alert at 50% of actual spend, created by the owner in the Azure portal at billing-account scope. It is **not** in Terraform and is not destroyed by teardown. Billing-account scope means it is account-wide: it also counts any non-project spend on the account. Recipient: the owner. Only one threshold (50%) exists today; a 90-100% threshold would give a later warning and should be added in the portal.
- **Alternatives:**
  - `azurerm_consumption_budget_subscription` in bootstrap: reproducible, but the CI identities have no subscription-scope rights, so it would be human-applied anyway and gains no automation benefit. (Putting it in the main config instead would mean teardown deletes the alarm.)
  - `azurerm_consumption_budget_resource_group` in the main config: misses spend outside `rg-gyazo-dev` (state account, AKS node resource group `MC_*`).
- **Trade-off:** Not reproducible from code, so it's recorded here and checked by hand. A budget only alerts; it never stops spending. The manual stops are `az aks stop` (which does not halt disk, ACR, storage or public IP costs) and the documented teardown.
- **Verify:** Portal → Cost Management → Budgets shows the $50 budget and its alert recipient.

## D-018 Terraform checks required on `main` — Accepted
- **Context:** In the M1 closeout review, `main` required only detect, actionlint, checkov and gitleaks. A PR breaking `terraform fmt`/validate/tflint or the dev plan could still merge.
- **Decision:** Also require `terraform fmt / validate / tflint` and `terraform plan (dev)` (repo setting, 2026-11-21; names must equal the job `name:` fields in `pr.yml`).
- **Alternatives:**
  - Keep them optional and rely on review: the reviewer sees the result, but nothing stops a merge.
  - Require the python and web jobs too: deferred until `app/` exists (M2): until then they only ever skip, so requiring them adds nothing.
- **Trade-off:** GitHub counts a job skipped by a job-level `if` as passing. The plan job skips when `AZURE_TENANT_ID` is missing, so deleting that variable would make the required plan check pass silently. Accepted for a solo demo; the variable is checked by the first PR plan after any settings change.

## D-019 One SAS code path, two signing keys (local Azurite vs Azure) — Accepted
- **Context:** `GET /i/<id>` redirects to a user-delegation SAS (D-004). Azurite can't issue Azure-compatible user-delegation keys, and its OAuth mode needs HTTPS plus hand-made tokens (azure/azurite#2412, still open). Shared keys are disabled in real Azure.
- **Decision:** The API always builds the URL with `generate_blob_sas`. `STORAGE_AUTH_MODE=key` (local only) signs with Azurite's public dev key; `STORAGE_AUTH_MODE=entra` (the default) signs with a user-delegation key from `DefaultAzureCredential`, cached for 1 hour and refreshed 10 minutes early. SAS is read-only, ≤ 5 minutes (enforced in config), with a 1-minute clock-skew allowance. Separate internal and browser-facing blob endpoints, because the browser follows the redirect.
- **Alternatives:**
  - Azurite `--oauth basic` with a self-signed cert and fake tokens: fragile, still not the real Entra path.
  - Develop against real Azure storage: needs a login and costs money, and every developer needs data-plane roles.
- **Trade-off:** The `entra` branch's signing shape (key caching, refresh, `skoid`/`sktid`, TTL) is unit-tested against a stubbed key service, but the real Entra call (user-delegation key with the Storage Blob Delegator role) is **untested** until it runs in AKS (M3).

## D-020 M2 runtime, encoding and CI choices — Accepted
- **Runtime pins:** Python 3.13 (azure-data-tables 12.7.0 doesn't yet list 3.14), Node 24 (vitest 5 needs ≥ 22.12), Azurite `3.38.0` with `--skipApiVersionCheck --loose`. Docker base images are pinned by tag; digests and image scanning come in M3.
- **Queue encoding:** Base64 text. Both clients set `TextBase64EncodePolicy` explicitly; the worker has no SDK decode policy and base64-decodes each message itself in `parse_message`. The SDK's own default is no encoding; Base64 matches Azure Functions and the portal, and KEDA only counts messages. **Gotcha found in review:** `QueueServiceClient.get_queue_client()` silently drops `message_encode_policy`, so the first version sent plain text despite "pinning". Both sides now build `QueueClient` directly, regression tests assert the policy on each client, and the worker decodes per message (a bad message is dropped alone, instead of failing the batch).
- **Worker failure handling:** `handle()` never raises. An invalid image is marked `failed` immediately; any other error (download, processing, thumbnail write, table write) is retried via the visibility timeout; after 5 dequeues the job is marked `failed` and deleted. A job dequeued more than 5 times is retired *before* any work, which covers jobs that crash the process (OOM) without a Python exception. Processing is idempotent (thumbnail overwrite, entity merge), because delivery is at-least-once. Decompression bombs: a hard 40 MP cap read from the header, before decoding (Pillow alone only warns up to 80 MP).
- **Upload guard:** key, `Content-Length` presence (411) and size (413) are checked in middleware from headers alone, because multipart bodies are parsed and spooled before route dependencies run. The owner key must be ≥ 16 characters, or startup fails. A SAS-signing failure (e.g. Entra unreachable) returns 503, not 500.
- **Sync SDK clients:** FastAPI runs `def` routes in a threadpool. Async clients would add aiohttp for no gain at this scale.
- **CI:** a new `e2e (compose + smoke)` job builds both images and runs `scripts/smoke.py` against Azurite + API + worker. Checkov now also scans Dockerfiles; `CKV_DOCKER_2` (HEALTHCHECK) is skipped inline, because Kubernetes uses probes. Gitleaks allowlists only Azurite's public dev key (`.gitleaks.toml`).
- **Required checks (retro rule):** `python lint / test`, `web lint / test / build` and `e2e (compose + smoke)` become required on `main` once this PR is green. They always run now that `app/` exists.

## D-021 AKS cluster shape (M3) — Accepted (researched 2026-11-24)
- **Context:** M3 creates the first billable compute. The cluster must run the API and worker with workload identity (D-005), pull from the Basic ACR, read the owner key from Key Vault, and expose one public gateway (D-008, D-011), at the lowest cost that still shows real platform practice. Argument names were checked against azurerm 5.14.0 with `terraform validate`.
- **Decision** (`infra/terraform/modules/aks`):
  - **Control plane:** `aks-gyazo-<env>`, **Free** tier, Kubernetes **1.36**, `automatic_upgrade_channel = "patch"`, `node_os_upgrade_channel = "NodeImage"`. 1.36 is offered in centralus (**verified** 2026-11-24 with `az aks get-versions`: patches 1.36.0–1.36.5).
  - **Network (D-007):** Azure CNI **Overlay**. Pod CIDR `10.244.0.0/16`, service CIDR `10.0.0.0/16`, DNS `10.0.0.10`. These overlap neither the VNet `10.20.0.0/16` nor each other. Outbound goes through the standard load balancer. No custom subnet NSG: AKS manages the node NSG and opens exactly the ports of each LoadBalancer Service (this resolves the M1 "deferred to M3" note on `snet-aks`).
  - **Identity and access:** OIDC issuer + workload identity on. The api/worker UAMIs get federated credentials for `system:serviceaccount:gyazo:api` and `system:serviceaccount:gyazo:worker`. The Key Vault Secrets Store CSI add-on is on, with rotation. **Local accounts are off, with Entra ID auth + Azure RBAC** and no admin groups (azurerm 5.14 still needs `tenant_id` in the block). The owner gets *Azure Kubernetes Service RBAC Cluster Admin*, and ci-plan gets *Azure Kubernetes Service Cluster User Role*, both at RG scope, from `infra/bootstrap` (PR #14).
  - **Apply order:** bootstrap PR #14 must be **applied before this config's first apply**. Bootstrap also adds the ci-apply ABAC allowlist entries. Without them, the three new role assignments (two Network Contributor, one AcrPull) are denied partway through the apply, and the destroy guard (D-016) then blocks the cleanup.
  - **ci-plan Cluster User Role:** ci-plan gets *Azure Kubernetes Service Cluster User Role* at RG scope (bootstrap PR #14).
    - *Why:* the azurerm refresh of the cluster calls the `listClusterUserCredential` POST, which Reader doesn't include, so PR plans would fail with a 403.
    - *Condition:* this is safe **only** while local accounts are disabled and Azure RBAC is on. Then the returned kubeconfig is Entra-only and grants no in-cluster rights by itself. With local accounts on, the same call returns a usable static credential. A lifecycle `precondition` in `modules/aks` asserts `local_account_disabled = true`.
  - **Run command off:** `run_command_enabled = false`. `az aks command invoke` goes through ARM and so bypasses the authorized IP ranges.
  - **API server authorized IPs are managed outside Terraform.** The cluster is created with `["0.0.0.0/32"]` (AKS's value for "only the cluster's own outbound IP"). After that, the owner runs `az aks update --api-server-authorized-ip-ranges <ip>/32`, and Terraform ignores the attribute (`ignore_changes`). This keeps the owner's home IP out of a public repo and out of CI, and CI applies don't reset it.
    - *Runbook:* because the ranges live outside Terraform, check them after each apply with `az aks show -g rg-gyazo-dev -n aks-gyazo-dev --query apiServerAccessProfile`. If the ranges are cleared, the API server becomes reachable from anywhere (Entra auth + Azure RBAC still apply).
  - **Nodes:** one autoscaled **system** pool, `Standard_D2s_v6` (D-013), min 1 / max 2 (variables), max surge 1, no zones, **managed** 64 GB OS disk (Dsv6 has no ephemeral OS disk support; the default is 128 GB). `temporary_name_for_rotation = "systemtmp"`, so changes to immutable pool properties rotate through a temporary pool instead of replacing the cluster. `max_pods = 250` (the overlay default, set explicitly). KEDA (M4) scales pods; the cluster autoscaler scales nodes, capped at 2 for cost.
  - **Control-plane identity:** user-assigned `id-gyazo-aks-<env>` with **Network Contributor** on the `snet-aks` subnet and on the gateway public IP (both `principal_type = ServicePrincipal`; the cluster `depends_on` both grants). The kubelet identity gets **AcrPull** on the registry. These roles are allowlisted for ci-apply in bootstrap.
  - **Gateway public IP (D-011):** `pip-gyazo-<env>`, Standard, Static, label `gyazo-<env>-<suffix>`, zone-redundant (zones set explicitly so a server-side default can't show up as a replacement). It lives in `modules/network`, in `rg-gyazo-<env>`, so the hostname survives cluster rebuilds.
  - **Network policy:** Azure CNI Powered by Cilium on overlay: `network_data_plane = "cilium"` + `network_policy = "cilium"`. `advanced_networking` (ACNS) is left unset because it's paid.
    - *Alternatives:* Azure NPM (Linux NPM retires 2028-09-30); Calico (the fallback if Cilium causes problems); no network policy (weak posture, pods can reach each other freely).
    - *Consequences:* changing the dataplane later reimages every node, and some network-profile changes force cluster replacement. No FQDN or L7 policy (those are ACNS-only). For in-cluster traffic, write policies with `namespaceSelector` + `podSelector`, not `ipBlock`. Policies don't apply to `hostNetwork` pods. The Cilium agent takes roughly 200-400 MiB per node (estimate, to be checked with `kubectl top` after apply).
    - *Sources:* learn.microsoft.com/azure/aks/use-network-policies, learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium (researcher, 2026-11-24).
  - **ACR:** pinned to `role_assignment_mode = "LegacyRegistryPermissions"`. The ABAC "repository permissions" mode ignores AcrPull and is slated to become the default.
- **Review rule (IAM):** Network Contributor (newly allowlisted for ci-apply) may be assigned **only** to the AKS control-plane UAMI, and **only** at the `snet-aks` and gateway-PIP resource scopes. Never at RG scope, and never to the api/worker identities. The ci-apply ABAC condition can't enforce a scope narrower than the RG, so the reviewer enforces this on every diff. The same rule is a comment next to both assignments in `modules/aks`.
- **Review rule (in-cluster RBAC, M3+ manifests):** never create a `RoleBinding` or `ClusterRoleBinding` to `system:authenticated` or to broad Entra groups. Azure RBAC and Kubernetes RBAC are additive. Every Entra principal that can fetch a kubeconfig (including ci-plan through its Cluster User Role) authenticates as `system:authenticated`, so it would gain those in-cluster rights.
- **Alternatives:**
  - Standard tier (~$73/month, SLA): no value for a one-week demo.
  - Private cluster: needs a jumpbox/VPN (D-007).
  - Authorized IPs in tfvars or a CI secret: the IP lands in a public repo or gets reset by every CI apply.
  - Separate system and user pools: twice the minimum node cost.
  - Ephemeral OS disk: not supported on Dsv6.
  - System-assigned control-plane identity: can't be granted Network Contributor before the cluster exists, so creating the cluster would race the grant.
  - Network Contributor at RG scope in bootstrap: much broader than needed.
  - A custom role with only `subnets/join` + `publicIPAddresses/join`: tighter, but needs a custom role definition and a new allowlist entry. Revisit if the review rule proves hard to hold.
- **Why:** cheapest shape that still demonstrates workload identity, Entra-only cluster access, KV CSI, an autoscaler and managed upgrades.
- **Cost (re-checked 2026-11-24):**
  - **Per node:** about $3/day.
    - D2s_v6 at $0.114/h ≈ $2.74/day (**verified**: Azure retail prices API, researcher).
    - 64 GB Premium SSD OS disk ≈ $0.3/day (**unverified**).
  - **Fixed:** about $0.85/day.
    - Standard load balancer ≈ $0.6/day (**unverified**).
    - Two Standard public IPs (gateway + AKS outbound) ≈ $0.24/day (**unverified**).
  - **Total:** about $4/day with 1 node, always on. The Free control plane costs nothing. `az aks stop` saves node compute only. The public IPs (gateway + AKS outbound), the load balancer, disks, ACR and storage keep billing (D-017).
- **Risks:**
  - Microsoft Learn says system pools should have ≥ 2 nodes for resilience. Min 1 conflicts with that guidance, and is accepted for cost. Upgrades surge to 2.
  - The PIP-scoped Network Contributor grant is **untested until the first gateway Service (M3)**; it is inferred, not verified. If the cloud provider looks the IP up by address (`azure-load-balancer-ipv4` + `azure-load-balancer-resource-group`), it may need to list public IPs at RG scope. Mitigation: reference the IP by name (`service.beta.kubernetes.io/azure-pip-name`, a direct GET) in the M3 gateway Service. If that still fails, a broader grant is a **new owner decision**: the review rule above forbids RG scope as-is.
  - Encryption at host is off (checkov CKV_AZURE_227 skipped). It needs the `EncryptionAtHost` subscription feature registration, which is a subscription change. **Residual risk:** the node temp disk and caches (`emptyDir`, where uploads may buffer) are **not** host-encrypted. Only the managed OS disk has platform encryption.

## D-022 AI screenshot overview is core scope, after M4 — Accepted
- **Context:** The spec listed M-AI (a vision-model description per screenshot) as an optional "Later" stretch after M6. The owner decided on 2026-11-25 that the project shows cloud infrastructure *integrated with AI*, so the AI step is part of what's being demonstrated.
- **Decision:** M-AI becomes a milestone after M4, with requirements in `docs/spec.md` → "AI overview": an eval suite gating CI, privacy and retention decisions, caching and a cost metric, plain-text rendering, and a model-down failure experiment (experiment 5). The model, hosting and region stay open until M-AI starts, when the researcher compares them. The preference is a model hosted in our subscription, called with workload identity.
- **Alternatives:**
  - Keep it in "Later": that undersells the AI integration the project is meant to show.
  - Put it before M4: it needs the queue worker (the pluggable processor) and traces to measure latency, and those land in M4.
  - Put it after M6: it would then ship on GitOps, but it would come last, when time is shortest.
- **Trade-off:** It adds 2–3 days, plus model spend under the $50 budget. Eval runs in CI cost money on every prompt change, so each run is capped. Model access for CI needs a new IAM role, which the owner approves.

## D-023 App-security review: reviewer checklist plus `/security-review` on app PRs — Accepted
- **Context:** The reviewer's checklist covered secrets, IAM, network exposure and cost, but had no app-level items. M-AI (D-022) adds untrusted model output to a page that holds the owner key in `localStorage`. The owner asked whether a separate security agent was needed (2026-11-25) and approved this instead.
- **Decision:**
  - The reviewer gets item 3a "App security": untrusted input, auth and disclosure per route, XSS/CSP and text-only rendering, injection/SSRF, SAS scope, prompt injection, dependencies and images (M3 timing), and rejected-case tests.
  - For changes under `app/` and the M-AI processor, the orchestrator also runs the built-in `/security-review`. Its summary goes in the PR, and each finding is fixed or recorded here or in a known-gaps table.
- **Alternatives:**
  - A separate security agent on every PR: one more round trip, mostly wasted on infra-only PRs that the reviewer already checks for IAM and secrets.
  - The reviewer alone: no second, differently built pass on the code paths that handle untrusted input.
  - `/security-review` only at milestone close: findings would arrive after merge, when they cost more to fix.
- **Trade-off:** One extra step on app PRs. The checklist is **untested** until the next app PR uses it.

## D-024 CI image push identity — Accepted
- **Context:** M3 needs CI to build the app images and push them to ACR (`role_assignment_mode = "LegacyRegistryPermissions"`, D-021). No CI identity can push today: ci-plan is read-only, and ci-apply's ABAC condition can't grant itself or other CI identities anything.
- **Decision:** A third user-assigned identity `id-gyazo-ci-push` in `infra/bootstrap`.
  - **Trust:** federated credential `github-environment-push`, subject `repo:<owner>@<id>/<repo>@<id>:environment:push`. Jobs that declare an environment get the `:environment:<name>` subject even when triggered by `push` or `schedule`.
  - **GitHub environment `push`:** main-only deployment branch policy, no reviewers. Configured in GitHub repo settings, not Terraform (an unmanaged control). Created before the bootstrap apply, because GitHub auto-creates a rule-less environment the first time a workflow names it. **Verified:** `gh api .../environments` on 2026-11-26 shows `push` and `aks-power` with the custom branch policy `main`.
  - **Role:** **AcrPush** (pull + push, no delete), the documented CI push role in Legacy mode. The Repository Writer roles only apply in ABAC repository-permissions mode.
  - **Scope:** `rg-gyazo-<env>`, not the registry. Bootstrap runs before the main config creates the ACR on a rebuild, so a registry-scoped data lookup would break ordering. The RG holds exactly one registry.
  - **Review rule:** only one registry may exist in `rg-gyazo-<env>`; a second one would be pushable by CI. Not enforced in code: tracked as an M3 known gap (tighten to registry scope or add a check before M3 closes).
  - The ci-apply ABAC condition now excludes all four CI identities, so ci-apply can't widen ci-push.
- **Alternatives:**
  - ACR admin user: rejected, a shared long-lived secret (D-005).
  - Service principal with a client secret: rejected, a long-lived secret.
  - Reuse ci-apply: rejected. Apply's identity would become a registry writer, and every image push would need the human apply gate.
  - Registry-scoped assignment: tighter, but breaks bootstrap-before-main ordering on a rebuild (see Scope).
- **Why:** no secrets, the smallest built-in role that can push, and image pushes from `main` don't wait for the apply approval.
- **Trade-off:** any workflow on `main` that uses the `push` environment can push (and overwrite tags) in the registry. Tag immutability and image signing are not in scope. Mitigation: the cluster deploys by digest (the kustomization pins `@sha256:`), so overwriting a tag doesn't change what runs. A PR merged to `main` can still push a new image, which is why merges need review.
- **Open items:**
  - `az acr login` may also need a control-plane read role on the registry. **Untested**; no extra role added. The first live push run decides, and any added role is recorded here. To avoid needing one, `build.yml` skips the ARM lookup: it exchanges the Entra token for an ACR refresh token at `https://<registry>.azurecr.io/oauth2/exchange` (the documented ACR AAD flow) and runs `docker login` with it. Fallback if that fails: Reader on the registry.
  - Live OIDC login and push: **untested** until the push workflow runs.

## D-025 Nightly AKS stop via scheduled workflow — Accepted
- **Context:** The cluster costs about $4/day with one node, always on (D-021). Stopping it by hand when idle depends on remembering to. The budget (D-017) only alerts, it never stops spending.
- **Decision:** A scheduled GitHub Actions workflow stops the cluster nightly (and a manual dispatch can start it), using a fourth identity `id-gyazo-ci-aks-power` from `infra/bootstrap`.
  - **Trust:** federated credential `github-environment-aks-power`, subject `...:environment:aks-power`. Environment `aks-power`: main-only deployment branch policy, no reviewers (configured in GitHub).
  - **Role:** custom `gyazo AKS start-stop (<env>)`, defined and assignable only at `rg-gyazo-<env>`, with exactly `managedClusters/read`, `managedClusters/start/action` and `managedClusters/stop/action`. No data actions, so no credential or in-cluster access.
  - **Scope:** RG, so the grant survives a cluster rebuild. It covers only clusters in that RG.
  - The ci-apply ABAC condition excludes this identity too.
- **Alternatives:**
  - Azure Automation runbook: 500 free job-minutes/month, but a new resource plus more IAM (its own identity and role).
  - Logic App: also a new resource and identity, for one API call.
  - *Azure Kubernetes Service Contributor Role* (built-in): too broad, it also allows cluster update and delete. No built-in role is narrower.
  - An agent on standby: rejected. Agents only exist inside a session, and every cloud change would need approval anyway. Deterministic automation is the right tool.
- **Why:** no new Azure resources, no secrets, and the narrowest possible role.
- **Trade-offs:**
  - GitHub cron is best-effort (runs can be delayed or dropped) and is disabled after 60 days without repo activity in public repos.
  - Stopping saves node compute only. Disks, the two Standard public IPs, the load balancer, ACR and storage keep billing.
  - AKS allows a cluster to stay stopped for at most 12 months.
  - Admission webhooks with wildcard rules can block a stop.
  - Allow 15–30 minutes between a stop and the next start.
- **Open items:**
  - ~~`operationresults/read` may be needed~~ Not needed. **Verified:** scheduled stop run 46034881155 (2026-11-27, about 10 hours after the 06:17 UTC cron time; GitHub cron is best-effort) left the cluster `Stopped`, and `workflow_dispatch` start run 46049852772 brought it back to `Running`, with no 403 on either.

## D-026 Image build, scan and supply-chain pins (M3) — Accepted
- **Context:** M3 deploys the first images to AKS. The M2 gap said base images were pinned by tag only and nothing scanned them. In March 2026 the `aquasecurity/trivy-action` tags 0.0.1–0.34.2 were force-pushed to malicious commits (CVE-2026-33634), so how the scanner itself is pinned matters too.
- **Decision:**
  - `build.yml` builds both images on every PR and on `main`, and scans them with Trivy (action pinned to the commit SHA of the immutable release v0.36.0, Trivy binary pinned to v0.76.2, never `latest`). The gate fails on **fixable** HIGH/CRITICAL vulnerabilities (`ignore-unfixed`).
  - PR runs get no Azure token. On `main`, a separate job in the `push` environment loads the exact scanned image and pushes it, tagged with the commit SHA (D-024). Deployments pin the digest, not the tag.
  - Base images are pinned `tag@sha256:digest`. Dependabot (`docker` ecosystem) refreshes digests and patch versions; node majors and Python minors/majors are ignored and done by hand.
  - The runtime stage runs `apt-get upgrade` and uninstalls pip.
  - **Required checks on `main`:** `image build + scan (api)` and `image build + scan (worker)`, added to the ruleset after their first run produces the names. The workflow has no path filter, so the checks always report and can't hang. The `push to ACR` jobs never run on PRs, so they are not required.
- **Why:**
  - The first local scan found 5 fixable HIGHs per image, none in our own dependencies: pip's vendored urllib3, msgpack and pkg_resources (setuptools) in the base image, plus Debian `libzstd1` (fixed in `deb13u1` but not yet in the official python image). The app runs from the uv virtualenv and never calls pip, so removing pip shrinks the attack surface instead of adding an ignore entry. **Verified (local, 2026-11-26):** after the fix both images scan clean (exit 0), `python -m pip` is absent, and `import gyazo_api.main` / `import gyazo_worker.processor` succeed in the images.
- **Alternatives:**
  - `.trivyignore` the pip findings: hides real code that ships in the image.
  - Wait for the upstream base image rebuild: blocks M3 on someone else's schedule; Dependabot catches up later anyway.
  - Distroless or Chainguard base images: fewer packages, but a bigger change to M2's tested images; revisit in M5.
  - Trivy from a digest-pinned container instead of the action: slightly more hardened; the immutable-release SHA pin is enough here.
- **Trade-offs:**
  - `apt-get upgrade` means the digest pin no longer fully determines the image; the apt layer depends on build day. Accepted for the CVE gate; Dependabot digest bumps make the step a no-op over time.
  - A required scan is a moving target: a newly published CVE or a Trivy DB outage can block unrelated PRs. Mitigation: a digest-bump PR, or a dated `.trivyignore` entry recorded here.
  - `ignore-unfixed` hides unfixed CVEs. A periodic full report is a known gap.
- **Untested:** the whole workflow on GitHub runners (first PR run), and the push job (first `main` run; needs the D-024 bootstrap apply and the `push` environment's `AZURE_CLIENT_ID`).

## D-027 First Kubernetes manifests: pod security, network policy, secret mount, image pins (M3) — Accepted
- **Context:** M3 deploys the api and worker to AKS for the first time, as raw manifests applied with `kubectl apply -k deploy/manifests` (Helm replaces them in M5). The choices here become the baseline the Helm chart must keep.
- **Decision:**
  - **Pod Security Admission:** namespace `gyazo` enforces `restricted`, pinned to `v1.36` (the cluster's minor version); `audit` and `warn` use `latest`. Pods run as uid 10001, non-root, all capabilities dropped, read-only root filesystem, `RuntimeDefault` seccomp, `automountServiceAccountToken: false`.
  - **NetworkPolicy:** default-deny ingress and egress in the namespace. Allows: ingress to api:8000 from `envoy-gateway-system` only; egress DNS to kube-dns; egress TCP 443 to `0.0.0.0/0` for api and worker (Storage, Entra token endpoint).
  - **Owner API key:** Key Vault secret `owner-api-key` mounted as a **file** by the Secrets Store CSI add-on using the api workload identity. No `secretObjects`, so it is never synced to a Kubernetes Secret and never placed in an env var. The worker identity has no Key Vault access.
  - **Images:** pinned by digest through kustomize `images:` (hand-pinned from build.yml run 45877215546; CI does not maintain them yet).
  - **Guardrail change:** the owner allowlisted exactly `deploy/manifests/secretproviderclass.yaml` in `.claude/hooks/block_secrets.py`. The file names a secret and must never hold a value; gitleaks in CI is the backstop.
- **Why:**
  - Pinning `enforce` to a version stops a cluster upgrade from silently tightening the policy and rejecting pods mid-deploy; `warn`/`audit` at `latest` surface what the next version would reject first.
  - Default-deny makes every allowed path explicit and reviewable. 443-anywhere is needed because Storage and Entra endpoints have no stable IP set; FQDN filtering needs a Cilium FQDN policy (Advanced Container Networking) or an egress firewall, both paid.
  - A file mount keeps the secret out of `kubectl describe`, env dumps and etcd; rotation is picked up by the add-on (`secret_rotation_enabled`).
  - Digests make the deployed bytes exactly the scanned bytes (D-026); a tag can be moved.
- **Alternatives:**
  - PSA `enforce: latest`: simpler, but an upgrade can break deploys.
  - Env var from a synced Kubernetes Secret: common, but the value lands in etcd and process environments.
  - Egress via Azure Firewall / Cilium FQDN rules: tighter, costs money; revisit if a later threat model needs it.
  - Hook exception via a different filename (e.g. `spc-owner-key.yaml`): avoids touching the guardrail, but hides the file's purpose; the owner chose the explicit allowlist.
- **Trade-offs / residual risk:**
  - Pods can reach any host on 443 (data exfiltration path if the app is compromised). Plain HTTP, IMDS and other ports are blocked.
  - The Cilium claim that a `0.0.0.0/0` CIDR rule excludes in-cluster endpoints is design-verified only; a negative test is a known gap.
  - Digest pins are manual until CI/ArgoCD maintains them (M6).
- **Verified (first apply, 2026-11-27, owner-approved):** `kubectl apply -k --dry-run=server` accepted all 11 resources (after the namespace existed), which covers PSA `restricted` admission. Rollout succeeded with 0 restarts, and `/readyz` returned 200, so the CSI mount, the workload-identity token and storage access all worked. `scripts/smoke.py` passed 15/15 through a port-forward. ~~**Still untested:** the Cilium CIDR negative test (known gap).~~ **Verified 2026-11-27** (negative test, see `docs/spec.md` M2 known gaps): in-cluster targets on 443 are dropped, blob storage connects.

## D-028 Edge: Envoy Gateway v1.10.0 + cert-manager v1.21.3, upload limits at the gateway (M3) — Accepted (researched 2026-11-27)
- **Context:** D-008 chose Gateway API with Envoy Gateway and cert-manager, and D-011 chose a public-IP DNS label with Let's Encrypt HTTP-01. M3 now has to make them concrete: versions, where each piece runs, and the exact policy YAML. Two M2 gaps belong here: the spec's rate limit on `/upload`, and a request-size limit that doesn't trust `Content-Length`. One M3 gap too: api ingress admitted every pod in `envoy-gateway-system`.
- **Decision** (`deploy/edge`, install order and commands in its README):
  - **Versions:**
    - Envoy Gateway chart v1.10.0.
    - CRDs from `gateway-crds-helm` v1.10.0 (Gateway API v1.6.1, **standard** channel, plus the Envoy Gateway CRDs). They are rendered with `helm template` and applied server-side, so no Helm release owns them; the controller chart runs with `crds.enabled=false`.
    - cert-manager v1.21.3, with its CRDs from its chart (`keep`) and `config.gatewayAPI.enabled=true` through the chart's `ControllerConfiguration`.
    - The AKS managed Gateway API is **not** enabled (CRD ownership, D-008).
  - **Namespaces:** Pod Security enforce versions are pinned to v1.36 (D-027).
    - `envoy-gateway-system` (controller and proxy pods): enforce baseline, warn/audit restricted.
    - `cert-manager`: enforce restricted.
    - `edge` (Gateway, TLS Secret, ACME solver): enforce restricted.
  - **Proxy:**
    - EnvoyProxy `public-proxy`, referenced from GatewayClass `eg`: 1 replica, requests 100m/256Mi, memory limit 512Mi. EG then sets Envoy's overload-manager heap limit to 80% of that.
    - LoadBalancer Service bound **by name** to `pip-gyazo-dev` in `rg-gyazo-dev` (D-011, D-021).
    - `externalTrafficPolicy: Local`, the EG default, stated explicitly. It preserves the client source IP, which the per-IP rate limit depends on.
  - **Gateway `edge/public`:**
    - Listener `http:80`: routes from `edge` only. It carries the 308 redirect to HTTPS (method-preserving; for browsers only, since API clients must use https so the key never crosses plain http) and cert-manager's solver route. The solver's Exact path match outranks the redirect's PathPrefix `/`.
    - Listener `https:443`: routes from `gyazo` only. TLS terminates with Secret `gyazo-tls`, and the annotation `cert-manager.io/cluster-issuer: letsencrypt-staging` starts on staging.
    - Both listeners are pinned to the hostname. No ReferenceGrant is needed: routes reference same-namespace Services, and the cross-namespace parentRef is allowed by `allowedRoutes`.
  - **ClusterIssuers:** staging and prod, HTTP-01 through `gatewayHTTPRoute` (parentRef `public`, sectionName `http`).
    - Solver Service is `ClusterIP`; the cert-manager default is NodePort.
    - No `email`: it is optional in v1.21, and Let's Encrypt no longer sends expiry mail. The owner may add one; no personal address in the repo.
  - **Upload limits** (BackendTrafficPolicy on a dedicated HTTPRoute `gyazo/api-upload`, exact path `/upload`, all methods):
    - `requestBuffer` `limit: 10304Ki` (10 MiB + 64 KiB = 10,551,296 bytes, the API's own `body_limit`), `mode: BufferAndLimit`.
    - Local rate limit: `sourceCIDR` `Distinct` `0.0.0.0/0`, 10 requests/minute per IP. EG v1.10 keeps up to 10,000 per-IP buckets (LRU).
  - **Client limits** (ClientTrafficPolicy on the Gateway):
    - `maxRequestHeaderLimit: 32Ki`.
    - `requestHeadersReceivedTimeout: 10s` (slow headers).
    - `requestReceivedTimeout: 60s` (a 10 MiB upload needs about 1.4 Mbit/s).
    - No trusted `X-Forwarded-For` hops, so a client can't choose its own rate-limit key.
  - **Network policy:** api ingress now needs namespace `envoy-gateway-system` **and** the proxy pod labels (`app.kubernetes.io/{name=envoy,component=proxy,managed-by=envoy-gateway}`, `gateway.envoyproxy.io/owning-gateway-{name=public,namespace=edge}`). These are the labels in the proxy Deployment's selector in v1.10.0, so they are stable.
  - **App:** uvicorn gets `--forwarded-allow-ips 10.244.0.0/16` (the pod CIDR, D-021), so the client IP and scheme come from Envoy's headers. In 0.54.0, CIDRs are supported and the rightmost untrusted `X-Forwarded-For` entry wins. Under compose the peer is a Docker bridge address, so the headers are ignored locally, which is harmless.
  - **Smaller choices:**
    - Envoy Gateway topology-injector webhook disabled: the node pool has no zones, and it is one less webhook in the way of the nightly stop.
    - cert-manager leader election moved from `kube-system` to `cert-manager`.
    - Controllers get explicit small requests (EG 50m/256Mi; cert-manager components 10m/32-64Mi) with memory limits and no CPU limits.
- **Alternatives:**
  - **AKS application routing add-on with Gateway API** (GA, managed, Istio-based): the fallback. Per the researcher (2026-11-27), it can't configure request body size limits or rate limiting, which are the two things this slice exists for, and it runs heavier always-on pods (D-008).
  - **Istio add-on + EnvoyFilter:** limits are possible, but through raw Envoy config patches that are unsupported, fragile across upgrades and heavier to run.
  - **Envoy Gateway v1.9.4:** the fallback if v1.10.0 shows a regression. Same API for everything used here.
  - **Limits only in the app** (as in M2): the app can't refuse a body it is already receiving, and it can't rate-limit across restarts or replicas cheaply.
  - **A route-wide upload ceiling** as a selector-less rule: dropped. EG sets `AlwaysConsumeDefaultTokenBucket=false`, so that bucket only counts requests that match no other rule, and with the per-IP rule in place it would never count.
- **Why:** Gateway API is the current standard, and Envoy Gateway is its reference-style implementation. Both limits are first-class CRD fields here, not patches. Running cert-manager in-cluster keeps TLS free and automatic with no domain purchase (D-011).
- **Risks:**
  - **Let's Encrypt limits:** `cloudapp.azure.com` is **not** on the Public Suffix List, so certificates count against `azure.com`: 50 per week, shared with every Azure customer. Mitigation: staging first, production requested once, then the Secret is kept (README "Staging to production"). Fallback: own domain + Azure DNS zone (D-011).
  - **PIP binding by name** depends on the PIP-scoped Network Contributor grant. It is untested until the first Gateway Service (D-021); if it fails, a broader grant is an owner decision.
  - **Pod Security of the generated pods:** EG proxy and ACME solver pods are generated by controllers, so we don't write their specs.
    - Proxy: restricted-compatible per the v1.10.0 source, and admitted locally with no restricted warnings. Not seen on AKS yet, so `envoy-gateway-system` stays enforce baseline until the AKS install shows no warnings.
    - Solver: restricted-compatible per the cert-manager v1.21.3 source. Not run anywhere yet.
  - **`BufferAndLimit` buffers whole uploads in Envoy memory.** The per-IP limit bounds each client, not the total; many addresses at once could push Envoy into overload shedding (heap limit at 80% of 512Mi). Accepted for a demo.
  - **Client IP / rate-limit key:** this relies on Azure LB + `externalTrafficPolicy: Local` preserving the source IP. Needs a live test (the api log shows a public IP; 11 quick requests get a 429).
  - **Nightly stop:** cert-manager's webhook (`failurePolicy: Fail`, cert-manager resources only) vs `az aks stop` (D-025) is untested.
  - **Chart images:** pinned by tag through the chart version, not by digest.
  - **One proxy replica:** a proxy restart is a short public outage.
- **Evidence (2026-11-27):**
  - **Verified (local k3s v1.34 in Docker, throwaway, no cloud):**
    - The README install steps 0-4 ran as written. cert-manager pods were admitted under enforced `restricted`.
    - `kubectl apply -k deploy/edge --dry-run=server` and the apply passed CRD schema, CEL and cert-manager webhook validation.
    - Envoy Gateway reported GatewayClass Accepted, both listeners Programmed/ResolvedRefs, all three routes Accepted, and both policies Accepted.
    - The proxy pod carried exactly the NetworkPolicy labels, and its Service had `externalTrafficPolicy: Local` and both Azure annotations.
    - Through the proxy (in-cluster client, self-signed cert, stub backend):
      - 10,551,296 bytes → 200; one byte more → 413, also with chunked encoding and with PUT; other paths are not limited.
      - 12 requests to `/upload` → 10×200 then 429 with `retry-after`.
      - HTTP → 301 to `https://<host>/...` (tested with 301; changed to 308 after review, schema-validated, not re-run end to end).
      - Envoy appended the real peer to a client-supplied `X-Forwarded-For`.
      - A non-proxy pod in `envoy-gateway-system` was refused by the api NetworkPolicy.
    - The cert-manager controller was scaled to 0 for the test, so no ACME traffic was sent.
  - **Verified (live AKS, read-only):** no Gateway API or cert-manager CRDs exist yet. `kubectl apply -k deploy/manifests --dry-run=server` accepted the tightened NetworkPolicy (the only diff is the added podSelector). The three namespaces pass a server dry run.
  - **Verified (local Docker):** the api image builds; uvicorn 0.54.0 in it trusts 10.244.x.x and not 172.17.0.1 or the node subnet, and it parses the CMD.
  - **Untested:** everything on AKS (PIP binding, the real ACME issuance, Cilium enforcing the label selector, source-IP preservation through the Azure LB, Pod Security on AKS, stop/start). The new api image needs a CI build and a digest repin in `deploy/manifests/kustomization.yaml` before `--forwarded-allow-ips` is live.
