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

## D-008 Ingress controller — Proposed, *verify*
- **Context:** Community ingress-nginx has been retired (EOL March 2026).
- **Candidates:** AKS Application Routing add-on (check its current controller/Gateway API status), Gateway API with a supported implementation, Traefik.
- **Decision pending** researcher check before M3.

## D-009 Observability: kube-prometheus-stack + OTel Collector + Tempo + Loki, self-hosted — Accepted
- **Alternatives:** Azure Managed Prometheus/Grafana + App Insights (less to run, more Azure-specific, cost per GB).
- **Why:** Portable skills, full control for experiments, no per-GB ingest bill. Trade-off: we operate it.

## D-010 Ansible: optional M8 self-hosted GitHub runner VM in the VNet — Accepted (cuttable)
- **Why:** Gives Ansible genuine OS-level work (packages, runner service, hardening) and enables private-network CI later. Run from WSL (Ansible control node doesn't run natively on Windows).

## D-011 DNS / TLS — Proposed, *verify*
- **Proposal:** Azure public IP DNS label (`<label>.<region>.cloudapp.azure.com`) + cert-manager with Let's Encrypt. No domain purchase needed.
- **Alternative:** Buy a domain + Azure DNS zone (nicer URL, small cost).
