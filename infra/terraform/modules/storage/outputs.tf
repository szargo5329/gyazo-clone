output "account_id" {
  description = "ID of the storage account."
  value       = azurerm_storage_account.this.id
}

output "account_name" {
  description = "Name of the storage account."
  value       = azurerm_storage_account.this.name
}

output "blob_endpoint" {
  description = "Primary blob endpoint."
  value       = azurerm_storage_account.this.primary_blob_endpoint
}

output "queue_endpoint" {
  description = "Primary queue endpoint."
  value       = azurerm_storage_account.this.primary_queue_endpoint
}

output "table_endpoint" {
  description = "Primary table endpoint."
  value       = azurerm_storage_account.this.primary_table_endpoint
}

output "images_container_id" {
  description = "Resource Manager ID of the images container (narrowest role-assignment scope for blobs)."
  value       = azurerm_storage_container.images.id
}

output "images_container_name" {
  description = "Name of the images blob container."
  value       = azurerm_storage_container.images.name
}

output "image_jobs_queue_id" {
  description = "Resource Manager ID of the image-jobs queue (role-assignment scope)."
  value       = azurerm_storage_queue.image_jobs.id
}

output "image_jobs_queue_name" {
  description = "Name of the image-jobs queue."
  value       = azurerm_storage_queue.image_jobs.name
}

output "images_table_id" {
  description = "Resource Manager ID of the images table (role-assignment scope)."
  value       = azurerm_storage_table.images.resource_manager_id
}

output "images_table_name" {
  description = "Name of the images table."
  value       = azurerm_storage_table.images.name
}
