output "id" {
  description = "ID of the Key Vault (role-assignment scope)."
  value       = azurerm_key_vault.this.id
}

output "name" {
  description = "Name of the Key Vault."
  value       = azurerm_key_vault.this.name
}

output "vault_uri" {
  description = "Vault URI used by clients and the Secrets Store CSI driver."
  value       = azurerm_key_vault.this.vault_uri
}
