# infra/bootstrap

One-time, **human-only** Terraform config for the identity plane:

- `rg-gyazo-platform`: Terraform state storage account (`stgyazotf<suffix>`, container `tfstate`) and the CI identities.
- `rg-gyazo-dev`: created empty so role assignments can target it. The main config (`infra/terraform/envs/dev`) reads it with a data source.
- `id-gyazo-ci-plan` (read-only) and `id-gyazo-ci-apply` (write to `rg-gyazo-dev` only), each with a GitHub OIDC federated credential bound to a GitHub Environment (`plan` / `apply`). See `docs/decisions.md` D-012.
- `id-gyazo-ci-push`: AcrPush on `rg-gyazo-dev` (push app images to the one registry there; no delete). Environment `push`. See D-024.
- `id-gyazo-ci-aks-power`: custom role `gyazo AKS start-stop (dev)` on `rg-gyazo-dev` (read/start/stop AKS only). Environment `aks-power`, used by the nightly stop workflow. See D-025.

Anything that grants permissions to CI lives here, so CI can never widen its own access: the main config has no way to change these role assignments. `ci-apply` can create role assignments in `rg-gyazo-dev`, but an ABAC condition limits it to a fixed allowlist of roles, granted only to service principals and never to any of the four CI identities (see `roles.tf`).

## Prerequisites

- Terraform >= 1.15, Azure CLI.
- `az login` as a principal with **Owner** (or Contributor + Role Based Access Control Administrator) on the subscription. Bootstrap creates role assignments, so it needs to be able to write them.

## Run

```sh
az login
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

cd infra/bootstrap
terraform init
terraform plan -out=bootstrap.tfplan   # review: every role assignment is listed
terraform apply bootstrap.tfplan
terraform output
```

Non-secret inputs (region, owner tag, GitHub repo) are variable defaults in `variables.tf`.

## Before apply

Create the GitHub Environments that new federated credentials trust (step 2 below) **before** the apply, with their main-only branch policy. GitHub auto-creates an environment with no rules the first time a workflow names it, so a branch could otherwise mint a token for that subject first. `push` and `aks-power` were created this way on 2026-11-26.

A brand-new custom role can fail its first assignment with `RoleDefinitionDoesNotExist` (Entra/ARM propagation). Re-running the apply fixes it.

## After apply

1. Write `infra/terraform/envs/dev/backend.hcl` from `backend.hcl.example` using `state_resource_group_name` and `state_storage_account_name`. It isn't committed (generated names).
2. In GitHub repo settings, create the Environments:
   - `plan`: no reviewers. Variable `AZURE_CLIENT_ID` = `ci_plan_client_id`.
   - `apply`: required reviewer(s), deployment branches limited to `main`. Variable `AZURE_CLIENT_ID` = `ci_apply_client_id`.
   - `push`: no reviewers, deployment branches limited to `main`. Variable `AZURE_CLIENT_ID` = `ci_push_client_id`.
   - `aks-power`: no reviewers, deployment branches limited to `main`. Variable `AZURE_CLIENT_ID` = `ci_aks_power_client_id`.
   - Repo variables `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`.
   These are identifiers, not secrets, so they're variables, not GitHub secrets.
3. Role assignments can take a few minutes to propagate before the first `terraform init` against the remote backend works.

## Why local state is acceptable here

- **No secrets in it.** Shared keys are disabled on the state account, so there are no access keys to land in state. The managed identities have no client secrets (they use federated credentials). The state only holds resource IDs, names, client IDs and the role-assignment condition.
- **Tiny and rarely changed.** One human applies it once, and again only when the identity plane changes. No concurrent writers, so no locking needed.
- **Chicken-and-egg.** It creates the remote backend everyone else uses (D-006).
- **Recoverable.** If the file is lost, the resources can be re-imported (`terraform import`) or the platform RG recreated. The state file is gitignored (`*.tfstate`); keep a copy outside the repo if you want convenience.

## Teardown

Destroy the main config first, then `terraform destroy` here. Storage soft delete (7 days) keeps deleted state blobs recoverable until then.
