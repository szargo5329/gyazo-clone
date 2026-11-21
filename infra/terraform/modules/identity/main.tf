# Workload identities for the API and worker pods (D-005).
#
# TODO(M3): add azurerm_federated_identity_credential for each identity once the AKS
# cluster exists: issuer = AKS OIDC issuer URL, subject =
# system:serviceaccount:<namespace>:<serviceaccount>.
#
# Every role below must be on the ci-apply ABAC allowlist in infra/bootstrap/roles.tf,
# otherwise CI's apply is denied when creating it.

resource "azurerm_user_assigned_identity" "api" {
  name                = "id-gyazo-api-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "worker" {
  name                = "id-gyazo-worker-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

locals {
  # Static keys so for_each is known at plan time; scopes are the narrowest each
  # role supports (container / queue / table rather than the account).
  api_roles = {
    blob_contributor = {
      role  = "Storage Blob Data Contributor"
      scope = var.images_container_id
    }
    # The user delegation key (needed to sign user-delegation SAS, D-004) is an
    # account-level blobServices action, so container scope isn't enough.
    blob_delegator = {
      role  = "Storage Blob Delegator"
      scope = var.storage_account_id
    }
    table_contributor = {
      role  = "Storage Table Data Contributor"
      scope = var.images_table_id
    }
    queue_sender = {
      role  = "Storage Queue Data Message Sender"
      scope = var.image_jobs_queue_id
    }
    kv_secrets_user = {
      role  = "Key Vault Secrets User"
      scope = var.key_vault_id
    }
  }

  worker_roles = {
    blob_contributor = {
      role  = "Storage Blob Data Contributor"
      scope = var.images_container_id
    }
    queue_processor = {
      role  = "Storage Queue Data Message Processor"
      scope = var.image_jobs_queue_id
    }
    table_contributor = {
      role  = "Storage Table Data Contributor"
      scope = var.images_table_id
    }
  }
}

resource "azurerm_role_assignment" "api" {
  for_each = local.api_roles

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.api.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "worker" {
  for_each = local.worker_roles

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.worker.principal_id
  principal_type       = "ServicePrincipal"
}
