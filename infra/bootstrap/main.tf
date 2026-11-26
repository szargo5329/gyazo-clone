# Identity plane. Everything that grants permissions to CI lives here and is applied
# only by a human. The main config (infra/terraform), which CI may apply, can never
# widen CI's own access. See docs/decisions.md D-006 and D-012.

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

locals {
  base_tags = {
    project    = "gyazo-clone"
    owner      = var.owner
    managed_by = "terraform"
  }
  platform_tags = merge(local.base_tags, { env = "platform" })
  env_tags      = merge(local.base_tags, { env = var.env })

  github_oidc_issuer   = "https://token.actions.githubusercontent.com"
  github_oidc_audience = "api://AzureADTokenExchange"
}

# ---------------------------------------------------------------------------
# Resource groups
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "platform" {
  name     = "rg-gyazo-platform"
  location = var.location
  tags     = local.platform_tags
}

# Created empty here so role assignments can target it. The main config reads it
# with a data source and never manages the RG itself.
resource "azurerm_resource_group" "env" {
  name     = "rg-gyazo-${var.env}"
  location = var.location
  tags     = local.env_tags
}

# ---------------------------------------------------------------------------
# Terraform state storage
# ---------------------------------------------------------------------------

resource "random_string" "state_suffix" {
  length  = 5
  lower   = true
  numeric = true
  upper   = false
  special = false
}

resource "azurerm_storage_account" "state" {
  #checkov:skip=CKV_AZURE_206:LRS is enough for a one-week demo's state; versioning and soft delete cover accidental overwrite/delete.
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys are acceptable; CMK needs a Key Vault key plus identity and adds cost/complexity.
  #checkov:skip=CKV2_AZURE_33:Private endpoints deferred for cost (docs/spec.md Later); access requires Entra auth since shared keys are off.
  #checkov:skip=CKV_AZURE_59:Public endpoint needed by GitHub-hosted runners and the human's laptop; shared keys off, Entra RBAC only.
  #checkov:skip=CKV_AZURE_35:Default-deny firewall would block GitHub-hosted runners (dynamic IPs); Entra RBAC is the control.
  #checkov:skip=CKV_AZURE_33:Queue service is unused on the state account.
  name                     = "stgyazotf${random_string.state_suffix.result}"
  resource_group_name      = azurerm_resource_group.platform.name
  location                 = azurerm_resource_group.platform.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  local_user_enabled              = false
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  public_network_access           = "Enabled"

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  # Only affects SAS tokens; with shared keys off, only user-delegation SAS is possible anyway.
  sas_policy {
    expiration_period = "00.01:00:00"
    expiration_action = "Log"
  }

  tags = local.platform_tags
}

resource "azurerm_storage_container" "tfstate" {
  #checkov:skip=CKV2_AZURE_21:Classic blob analytics logging deferred; state access is auditable via Entra sign-in and Activity logs, diagnostics to Log Analytics cost money.
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

# ---------------------------------------------------------------------------
# CI identities (GitHub OIDC -> user-assigned managed identity)
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "ci_plan" {
  name                = "id-gyazo-ci-plan"
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  tags                = local.platform_tags
}

resource "azurerm_user_assigned_identity" "ci_apply" {
  name                = "id-gyazo-ci-apply"
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  tags                = local.platform_tags
}

# Subjects are GitHub Environments, not branches: the pull_request subject can't be
# pinned to a branch (D-012). The `apply` environment must have required reviewers
# and a main-only deployment branch rule, configured in GitHub repo settings.
resource "azurerm_federated_identity_credential" "ci_plan" {
  name                      = "github-environment-plan"
  user_assigned_identity_id = azurerm_user_assigned_identity.ci_plan.id
  issuer                    = local.github_oidc_issuer
  audience                  = [local.github_oidc_audience]
  subject                   = "repo:${var.github_subject_repo}:environment:plan"
}

resource "azurerm_federated_identity_credential" "ci_apply" {
  name                      = "github-environment-apply"
  user_assigned_identity_id = azurerm_user_assigned_identity.ci_apply.id
  issuer                    = local.github_oidc_issuer
  audience                  = [local.github_oidc_audience]
  subject                   = "repo:${var.github_subject_repo}:environment:apply"
}

# ci-push: builds and pushes app images from main. Separate from ci-apply so pushing
# an image never needs the apply approval gate and apply's identity is not a registry
# writer (D-024).
resource "azurerm_user_assigned_identity" "ci_push" {
  name                = "id-gyazo-ci-push"
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  tags                = local.platform_tags
}

# ci-aks-power: nightly scheduled stop (and manual start) of the AKS cluster (D-025).
resource "azurerm_user_assigned_identity" "ci_aks_power" {
  name                = "id-gyazo-ci-aks-power"
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  tags                = local.platform_tags
}

# The `push` and `aks-power` environments have a main-only deployment branch rule and
# no reviewers (configured in GitHub). Jobs that declare an environment get the
# `:environment:<name>` subject even when triggered by push or schedule.
resource "azurerm_federated_identity_credential" "ci_push" {
  name                      = "github-environment-push"
  user_assigned_identity_id = azurerm_user_assigned_identity.ci_push.id
  issuer                    = local.github_oidc_issuer
  audience                  = [local.github_oidc_audience]
  subject                   = "repo:${var.github_subject_repo}:environment:push"
}

resource "azurerm_federated_identity_credential" "ci_aks_power" {
  name                      = "github-environment-aks-power"
  user_assigned_identity_id = azurerm_user_assigned_identity.ci_aks_power.id
  issuer                    = local.github_oidc_issuer
  audience                  = [local.github_oidc_audience]
  subject                   = "repo:${var.github_subject_repo}:environment:aks-power"
}
