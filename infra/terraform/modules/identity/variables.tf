variable "env" {
  description = "Environment name used in resource names (e.g. dev)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to create the identities in."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "storage_account_id" {
  description = "ID of the app storage account (scope for Storage Blob Delegator)."
  type        = string
}

variable "images_container_id" {
  description = "Resource Manager ID of the images blob container."
  type        = string
}

variable "image_jobs_queue_id" {
  description = "Resource Manager ID of the image-jobs queue."
  type        = string
}

variable "images_table_id" {
  description = "Resource Manager ID of the images table."
  type        = string
}

variable "key_vault_id" {
  description = "ID of the Key Vault holding the owner API key."
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster (issuer of the federated credentials)."
  type        = string
}

variable "k8s_namespace" {
  description = "Kubernetes namespace of the app service accounts."
  type        = string
  default     = "gyazo"
}

variable "api_service_account" {
  description = "Kubernetes service account name used by the API pods."
  type        = string
  default     = "api"
}

variable "worker_service_account" {
  description = "Kubernetes service account name used by the worker pods."
  type        = string
  default     = "worker"
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
}
