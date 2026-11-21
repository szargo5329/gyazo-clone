# infra/bootstrap

One-time, **human-only** Terraform config for the identity plane:

- `rg-gyazo-platform`: Terraform state storage account (`stgyazotf<suffix>`, container `tfstate`) and the CI identities.
- `rg-gyazo-dev`: created empty so role assignments can target it. The main config (`infra/terraform/envs/dev`) reads it with a data source.
- `id-gyazo-ci-plan` (read-only) and `id-gyazo-ci-apply` (write to `rg-gyazo-dev` only), each with a GitHub OIDC federated credential bound to a GitHub Environment (`plan` / `apply`). See `docs/decisions.md` D-012.

Anything that grants permissions to CI lives here, so CI can never widen its own access: the main config has no way to change these role assignments. `ci-apply` can create role assignments in `rg-gyazo-dev`, but an ABAC condition limits it to a fixed allowlist of data-plane roles (see `roles.tf`).

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

## After apply

1. Write `infra/terraform/envs/dev/backend.hcl` from `backend.hcl.example` using `state_resource_group_name` and `state_storage_account_name`. It isn't committed (generated names).
2. In GitHub repo settings, create the Environments:
   - `plan`: no reviewers. Variable `AZURE_CLIENT_ID` = `ci_plan_client_id`.
   - `apply`: required reviewer(s), deployment branches limited to `main`. Variable `AZURE_CLIENT_ID` = `ci_apply_client_id`.
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
