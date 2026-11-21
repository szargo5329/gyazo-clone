# Basic SKU (~USD 5/month). The Premium-only features checkov asks for below are
# skipped deliberately for cost; images are pulled by AKS with AcrPull via managed identity.
resource "azurerm_container_registry" "this" {
  #checkov:skip=CKV_AZURE_139:Public endpoint needed by GitHub-hosted runners and AKS without private endpoints (Premium-only, deferred for cost).
  #checkov:skip=CKV_AZURE_163:Defender for Containers vulnerability scanning is a paid add-on; image scanning to be done in CI instead.
  #checkov:skip=CKV_AZURE_164:Content trust (signed images) is Premium-only.
  #checkov:skip=CKV_AZURE_165:Geo-replication is Premium-only; single-region demo (non-goal: HA/multi-region).
  #checkov:skip=CKV_AZURE_166:Quarantine policy is Premium-only.
  #checkov:skip=CKV_AZURE_167:Untagged-manifest retention policy is Premium-only.
  #checkov:skip=CKV_AZURE_233:Zone redundancy is Premium-only; single-zone demo.
  #checkov:skip=CKV_AZURE_237:Dedicated data endpoints are Premium-only.
  name                = "acrgyazo${var.env}${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"

  admin_enabled          = false # no username/password; pull/push via Entra RBAC only
  anonymous_pull_enabled = false

  tags = var.tags
}
