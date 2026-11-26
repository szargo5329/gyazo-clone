# Security model

Short threat model for a public, single-user demo. Each control is mapped to what it defends against, so it can be defended in an interview.

## Assets
1. Azure subscription (spend, and the ability to create resources).
2. Uploaded images, which are private until someone shares a link.
3. The owner API key, which authorizes uploads.
4. CI's Azure access.
5. Terraform state (resource IDs; no secrets, by design).

## Threats → controls

| Threat | Control | Where |
|---|---|---|
| Leaked long-lived cloud credentials | **No keys exist.** GitHub → Azure uses OIDC federation. Pods use workload identity. Storage `shared_access_key_enabled = false`, ACR admin user off. | D-005, D-012, Terraform |
| Malicious or compromised PR uses CI's Azure token | PR plan identity can't change anything: control-plane Reader, plus AKS Cluster User Role so plan can refresh the cluster. That role adds one credential-listing action (`listClusterUserCredential`); with local accounts disabled and Azure RBAC it yields only a kubeconfig stub with no in-cluster rights (D-021). Write identity is bound to the `apply` GitHub Environment, which requires the owner's approval, and runs only from `main`. Two narrow unattended identities run only from `main` (`push` / `aks-power` environments, no reviewers): `id-gyazo-ci-push` has AcrPush on `rg-gyazo-dev` (push images, no delete; only one registry may exist in that RG), and `id-gyazo-ci-aks-power` has a custom role limited to AKS read/start/stop. | D-012, D-024, D-025, bootstrap |
| CI escalates its own permissions | **Identity plane vs workload plane.** CI identities and their roles live in `infra/bootstrap`, applied only by a human. The apply identity can assign only an allowlist of data-plane roles plus Network Contributor (needed by the AKS control-plane identity; it grants network write: no data-plane or role-assignment rights, but it can alter network paths), only to service principals, and never to any CI identity (plan, apply, push, aks-power; RBAC Admin with an ABAC condition). This narrows CI power; Contributor on the RG remains, gated by apply approval. | bootstrap |
| Over-privileged app pods | One identity per workload. Data-plane roles scoped to a single container, queue or table, never account-wide (except Blob Delegator, which needs the account to issue user-delegation SAS). | identity module |
| Anonymous uploads or abuse of a public endpoint | `/upload` requires the owner key; ingress rate limit; size and type validation (magic bytes); KEDA `maxReplicaCount` caps worker spend. | D-001, spec |
| Image enumeration or guessing | 128-bit random IDs; no listing endpoint; container private; access only via SAS valid ≤ 5 min, signed by Entra (user-delegation), revocable. | D-004 |
| Secret committed to the public repo | Claude hook blocks secret-file writes; `.gitignore`; gitleaks in CI; owner key never in Terraform (it would land in state). Set with `az keyvault secret set`. | hooks, CI |
| Insecure IaC slips in | Checkov on every PR; reviewer agent checklist (secrets → IAM → exposure → cost); human reviews the `terraform plan` before every apply. | CI, workflow |
| Supply chain (Actions, images) | Actions pinned to SHAs + Dependabot. Images built in CI and pushed to private ACR, pulled via AcrPull identity. M3: image scanning (Trivy) + pinned base images. | pr.yml |
| Branch tampering | `main` protected: PR required, required status checks, no force push or deletion. | GitHub settings |
| XSS stealing the owner key (stored in browser localStorage) | Strict CSP (no inline scripts, same-origin only); key only sent to `/upload`. | spec |
| Runaway cost | Budget alert ($50/month, alert at 50%; created manually at billing-account scope, not in Terraform, see D-017); small node pool with autoscaler max; nightly scheduled `az aks stop` (D-025); documented teardown. | spec, D-017 |

## Accepted risks (documented trade-offs)
- **Public endpoints on Storage, Key Vault and the AKS API server.** They're protected by Entra auth, RBAC and (for AKS) authorized IP ranges. Private endpoints cost about $7/month each plus DNS complexity. Revisit with M8.
- **No customer-managed keys or geo-redundancy:** demo data, Microsoft-managed encryption at rest.
- **Key Vault purge protection off,** so teardown and recreation within a week works.
- **Single owner key, no rotation automation.** Rotate manually by setting a new secret version.
- **Bootstrap state is local (gitignored).** It is not just IDs: azurerm records the state storage account's access keys in it. Those keys are unusable while `shared_access_key_enabled = false` (verified 2026-11-21: `allowSharedKeyAccess: false` on both accounts), but anyone who could re-enable shared keys and read this file would gain access. Keep the file off shared drives, and treat it as sensitive. Found by a local gitleaks scan in M2.

## Who reviews security
No dedicated security agent; see D-014. Security is the reviewer agent's **first** priority, backed by deterministic scanners (Checkov, gitleaks, actionlint) and the human `terraform plan` gate.
