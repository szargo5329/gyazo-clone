resource "azurerm_virtual_network" "this" {
  name                = "vnet-gyazo-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.address_space]
  tags                = var.tags
}

# Nodes only (D-007: Azure CNI Overlay assigns pod IPs from an overlay CIDR, not this subnet).
# No NSG here yet: AKS creates and manages the NSG on the node resource group's NICs.
# A custom NSG will be revisited with the M3 cluster if ingress needs tightening.
resource "azurerm_subnet" "aks" {
  #checkov:skip=CKV2_AZURE_31:AKS manages the node NSG; a custom subnet NSG is deferred to M3 (see comment above).
  name                 = "snet-aks"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aks_subnet_prefix]

  # No implicit "default outbound" internet access; AKS egress goes through its
  # own load balancer outbound rules (outboundType loadBalancer, M3).
  default_outbound_access_enabled = false
}

# Reserved for private endpoints (deferred for cost) or the M8 runner VM. Unused now.
resource "azurerm_subnet" "pe" {
  #checkov:skip=CKV2_AZURE_31:Empty reserved subnet; an NSG is added with its first workload (M8 runner) if any.
  name                 = "snet-pe"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.pe_subnet_prefix]

  default_outbound_access_enabled = false
}
