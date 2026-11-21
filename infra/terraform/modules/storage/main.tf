# One account for blobs (images), the job queue and the metadata table (D-003):
# one identity, one RBAC boundary. Shared keys are off (D-004/D-005), so every
# client, including Terraform (provider storage_use_azuread = true), uses Entra ID.
resource "azurerm_storage_account" "this" {
  #checkov:skip=CKV_AZURE_206:LRS on purpose: single-region demo, HA/backups beyond soft delete are non-goals (docs/spec.md).
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys are acceptable; CMK needs a Key Vault key plus identity and adds cost/complexity.
  #checkov:skip=CKV2_AZURE_33:Private endpoints deferred for cost (docs/spec.md Later); shared keys off, Entra RBAC only.
  #checkov:skip=CKV_AZURE_59:Public endpoint required until private endpoints exist: browsers fetch images via user-delegation SAS (D-004).
  #checkov:skip=CKV_AZURE_35:Default-deny firewall would break SAS redirects to browsers and GitHub-hosted runners; Entra RBAC is the control.
  #checkov:skip=CKV_AZURE_33:Classic queue analytics logging not enabled: demo data, no compliance need; access is auditable via Entra sign-in + Activity logs. Revisit if storage diagnostics are added in M7.
  name                     = "stgyazo${var.env}${var.suffix}"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  local_user_enabled              = false
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  # Private endpoints are deferred for cost (docs/spec.md "Later", docs/decisions.md D-004).
  # Access is still Entra-only because shared keys are disabled.
  public_network_access = "Enabled"

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = var.soft_delete_days
    }

    container_delete_retention_policy {
      days = var.soft_delete_days
    }
  }

  # Only affects SAS tokens; the app issues user-delegation SAS valid <= 5 minutes.
  sas_policy {
    expiration_period = "00.01:00:00"
    expiration_action = "Log"
  }

  tags = var.tags
}

# storage_account_id makes these go through the ARM control plane, which works
# with shared keys disabled.
resource "azurerm_storage_container" "images" {
  #checkov:skip=CKV2_AZURE_21:Classic blob analytics logging not enabled: demo data, no compliance need; access is auditable via Entra sign-in + Activity logs. Revisit if storage diagnostics are added in M7.
  name                  = "images"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_storage_queue" "image_jobs" {
  name               = "image-jobs"
  storage_account_id = azurerm_storage_account.this.id
}

resource "azurerm_storage_table" "images" {
  #checkov:skip=CKV2_AZURE_20:Classic table analytics logging not enabled: demo data, no compliance need; access is auditable via Entra sign-in + Activity logs. Revisit if storage diagnostics are added in M7.
  name               = "images"
  storage_account_id = azurerm_storage_account.this.id
}
