output "vnet_id" {
  description = "ID of the virtual network."
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "Name of the virtual network."
  value       = azurerm_virtual_network.this.name
}

output "aks_subnet_id" {
  description = "ID of the AKS node subnet."
  value       = azurerm_subnet.aks.id
}

output "pe_subnet_id" {
  description = "ID of the reserved private-endpoint/runner subnet."
  value       = azurerm_subnet.pe.id
}

output "gateway_public_ip_id" {
  description = "ID of the gateway public IP."
  value       = azurerm_public_ip.gateway.id
}

output "gateway_public_ip_name" {
  description = "Name of the gateway public IP (for the gateway Service's azure-pip-name annotation)."
  value       = azurerm_public_ip.gateway.name
}

output "gateway_public_ip_address" {
  description = "Static IPv4 address of the gateway public IP."
  value       = azurerm_public_ip.gateway.ip_address
}

output "gateway_fqdn" {
  description = "DNS name of the gateway (<label>.<region>.cloudapp.azure.com, D-011)."
  value       = azurerm_public_ip.gateway.fqdn
}
