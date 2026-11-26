output "id" {
  description = "ID of the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.id
}

output "name" {
  description = "Name of the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.name
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster (issuer of workload identity federated credentials)."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "node_resource_group" {
  description = "AKS-managed node resource group (MC_*)."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "kubelet_object_id" {
  description = "Object ID of the kubelet identity (holder of AcrPull)."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "control_plane_principal_id" {
  description = "Principal ID of the control-plane identity id-gyazo-aks-<env>."
  value       = azurerm_user_assigned_identity.control_plane.principal_id
}
