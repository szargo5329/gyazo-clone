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
  - **Control plane:** `aks-gyazo-<env>`, **Free** tier, Kubernetes **1.36**, `automatic_upgrade_channel = "patch"`, `node_os_upgrade_channel = "NodeImage"`.
  - **Network (D-007):** Azure CNI **Overlay**. Pod CIDR `10.244.0.0/16`, service CIDR `10.0.0.0/16`, DNS `10.0.0.10`. These overlap neither the VNet `10.20.0.0/16` nor each other. Outbound goes through the standard load balancer. No custom subnet NSG: AKS manages the node NSG and opens exactly the ports of each LoadBalancer Service (this resolves the M1 "deferred to M3" note on `snet-aks`).
  - **Identity and access:** OIDC issuer + workload identity on. The api/worker UAMIs get federated credentials for `system:serviceaccount:gyazo:api` and `system:serviceaccount:gyazo:worker`. The Key Vault Secrets Store CSI add-on is on, with rotation. **Local accounts are off, with Entra ID auth + Azure RBAC** and no admin groups (azurerm 5.14 still needs `tenant_id` in the block). The owner gets *Azure Kubernetes Service RBAC Cluster Admin* at RG scope via `infra/bootstrap`.
  - **API server authorized IPs are managed outside Terraform.** The cluster is created with `["0.0.0.0/32"]` (AKS's value for "only the cluster's own outbound IP"). After that, the owner runs `az aks update --api-server-authorized-ip-ranges <ip>/32`, and Terraform ignores the attribute (`ignore_changes`). This keeps the owner's home IP out of a public repo and out of CI, and CI applies don't reset it.
  - **Nodes:** one autoscaled **system** pool, `Standard_D2s_v6` (D-013), min 1 / max 2 (variables), max surge 1, no zones, **managed** OS disk (Dsv6 has no ephemeral OS disk support). `max_pods = 250` (the overlay default, set explicitly). KEDA (M4) scales pods; the cluster autoscaler scales nodes, capped at 2 for cost.
  - **Control-plane identity:** user-assigned `id-gyazo-aks-<env>` with **Network Contributor** on the `snet-aks` subnet and on the gateway public IP (both `principal_type = ServicePrincipal`; the cluster `depends_on` both grants). The kubelet identity gets **AcrPull** on the registry. These roles are allowlisted for ci-apply in bootstrap.
  - **Gateway public IP (D-011):** `pip-gyazo-<env>`, Standard, Static, label `gyazo-<env>-<suffix>`, zone-redundant (zones set explicitly so a server-side default can't show up as a replacement). It lives in `modules/network`, in `rg-gyazo-<env>`, so the hostname survives cluster rebuilds.
  - **Network policy:** Azure CNI Powered by Cilium on overlay: `network_data_plane = "cilium"` + `network_policy = "cilium"`. `advanced_networking` (ACNS) is left unset because it's paid.
    - *Alternatives:* Azure NPM (Linux NPM retires 2028-09-30); Calico (the fallback if Cilium causes problems); no network policy (weak posture, pods can reach each other freely).
    - *Consequences:* changing the dataplane later reimages every node, and some network-profile changes force cluster replacement. No FQDN or L7 policy (those are ACNS-only). For in-cluster traffic, write policies with `namespaceSelector` + `podSelector`, not `ipBlock`. Policies don't apply to `hostNetwork` pods. The Cilium agent takes roughly 200-400 MiB per node (estimate, to be checked with `kubectl top` after apply).
    - *Sources:* learn.microsoft.com/azure/aks/use-network-policies, learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium (researcher, 2026-11-24).
  - **ACR:** pinned to `role_assignment_mode = "LegacyRegistryPermissions"`. The ABAC "repository permissions" mode ignores AcrPull and is slated to become the default.
- **Review rule (IAM):** Network Contributor (newly allowlisted for ci-apply) may be assigned **only** to the AKS control-plane UAMI, and **only** at the `snet-aks` and gateway-PIP resource scopes. Never at RG scope, and never to the api/worker identities. The ci-apply ABAC condition can't enforce a scope narrower than the RG, so the reviewer enforces this on every diff. The same rule is a comment next to both assignments in `modules/aks`.
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
- **Cost (estimate, untested):** about $4.30/day per node, always on (D2s_v6 + managed disk). The Free control plane costs nothing. `az aks stop` saves node compute only. The public IPs (gateway + AKS outbound), the load balancer, disks, ACR and storage keep billing (D-017).
- **Risks:**
  - Microsoft Learn says system pools should have ≥ 2 nodes for resilience. Min 1 conflicts with that guidance, and is accepted for cost. Upgrades surge to 2.
  - The PIP-scoped grant is **inferred**, not verified. If the cloud provider looks the IP up by address (`azure-load-balancer-ipv4` + `azure-load-balancer-resource-group`), it may need to list public IPs at RG scope. Mitigation: reference the IP by name (`service.beta.kubernetes.io/azure-pip-name`, a direct GET) in the M3 gateway Service. If that still fails, a broader grant is a **new owner decision**: the review rule above forbids RG scope as-is.
  - Encryption at host is off (needs the `EncryptionAtHost` subscription feature registration, a subscription change). Disks use platform-managed keys.

