variable "env" {
  description = "Environment name used in resource names (e.g. dev)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group for the cluster and its control-plane identity."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tenant_id" {
  description = "Entra tenant ID used for cluster authentication (Azure RBAC)."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version (patches are applied by the `patch` upgrade channel)."
  type        = string
  default     = "1.36"
}

variable "node_vm_size" {
  description = "VM size of the system node pool (D-013)."
  type        = string
  default     = "Standard_D2s_v6"
}

variable "node_min_count" {
  description = "Minimum node count of the autoscaled system pool."
  type        = number
  default     = 1

  validation {
    condition     = var.node_min_count >= 1
    error_message = "The node_min_count value must be at least 1."
  }
}

variable "node_max_count" {
  description = "Maximum node count of the autoscaled system pool (cost cap, D-021)."
  type        = number
  default     = 2

  validation {
    condition     = var.node_max_count >= 1 && var.node_max_count <= 3
    error_message = "The node_max_count value must be between 1 and 3 (vCPU quota and cost cap)."
  }
}

variable "aks_subnet_id" {
  description = "ID of the node subnet (snet-aks). The control-plane identity gets Network Contributor on it."
  type        = string
}

variable "gateway_public_ip_id" {
  description = "ID of the gateway public IP (D-011). The control-plane identity gets Network Contributor on it so the cloud provider can attach it to the cluster load balancer."
  type        = string
}

variable "acr_id" {
  description = "ID of the container registry. The kubelet identity gets AcrPull on it."
  type        = string
}

variable "pod_cidr" {
  description = "Azure CNI Overlay pod CIDR. Must not overlap the VNet (10.20.0.0/16) or the service CIDR."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes service CIDR. Must not overlap the VNet or the pod CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "dns_service_ip" {
  description = "Cluster DNS service IP; must sit inside service_cidr."
  type        = string
  default     = "10.0.0.10"
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
}
