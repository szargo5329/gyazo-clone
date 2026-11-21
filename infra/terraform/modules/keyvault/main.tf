# Holds the owner API key (D-001), mounted into the API pod via the Secrets Store
# CSI driver (M3).
#
# The secret itself is NOT created in Terraform: its value would be stored in plain
# text in Terraform state. A human sets it after apply, e.g.
#   az keyvault secret set --vault-name <vault> --name owner-api-key --value "$(openssl rand -base64 32)"
# (that needs a data-plane role such as Key Vault Secrets Officer on the vault).
resource "azurerm_key_vault" "this" {
  #checkov:skip=CKV_AZURE_42:Purge protection off on purpose: it would keep the deleted vault (and its cleanup) blocked for the soft-delete period after teardown. Accepted risk in docs/security.md.
  #checkov:skip=CKV_AZURE_110:Purge protection off on purpose: it would keep the deleted vault (and its cleanup) blocked for the soft-delete period after teardown. Accepted risk in docs/security.md.
  #checkov:skip=CKV_AZURE_109:Default-deny firewall deferred with private endpoints (cost); RBAC authorization is the control.
  #checkov:skip=CKV_AZURE_189:Public endpoint required until private endpoints exist (deferred for cost, docs/spec.md Later).
  #checkov:skip=CKV2_AZURE_32:Private endpoints deferred for cost (docs/spec.md Later).
  name                = "kv-gyazo-${var.env}-${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  # Azure RBAC instead of legacy access policies: same role-assignment model as
  # everything else, and grants are scoped/auditable like any other Azure role.
  rbac_authorization_enabled = true

  soft_delete_retention_days = var.soft_delete_retention_days
  # Demo torn down after about a week. Purge protection can't be turned off once
  # enabled, and it would block recreating a vault with the same name (and purging
  # the deleted one) for the whole retention period.
  purge_protection_enabled = false

  # Private endpoints deferred for cost, same as storage (docs/spec.md "Later").
  public_network_access_enabled = true

  tags = var.tags
}
