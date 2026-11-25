resource "azurerm_virtual_network" "this" {
  name                = "vnet-gyazo-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.address_space]
  tags                = var.tags
}

# Nodes only (D-007: Azure CNI Overlay assigns pod IPs from an overlay CIDR, not this subnet).
# No custom subnet NSG (decided in M3, D-021): AKS creates and manages an NSG on the
# node NICs and opens exactly the ports of each LoadBalancer Service. A subnet NSG
# would duplicate those rules by hand (LB probes, gateway 80/443) for no extra control.
resource "azurerm_subnet" "aks" {
  #checkov:skip=CKV2_AZURE_31:AKS manages the node NSG and its LoadBalancer rules; no custom subnet NSG by decision (D-021).
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

# Gateway ingress IP (D-011). Lives in the workload RG, outside the cluster
# lifecycle, so the DNS name survives cluster rebuilds. The gateway's LoadBalancer
# Service attaches it via annotations; the AKS control-plane identity gets Network
# Contributor on it (modules/aks).
resource "azurerm_public_ip" "gateway" {
  name                = "pip-gyazo-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  allocation_method   = "Static"
  domain_name_label   = "gyazo-${var.env}-${var.suffix}"

  # Set explicitly: Azure now makes zone-less Standard IPs zone-redundant, and a
  # server-side zones value would show up as a forced replacement on a later plan.
  zones = var.gateway_pip_zones

  tags = var.tags
}
