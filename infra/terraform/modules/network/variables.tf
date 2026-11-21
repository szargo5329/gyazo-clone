variable "env" {
  description = "Environment name used in resource names (e.g. dev)."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to create the network in."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "address_space" {
  description = "VNet address space."
  type        = string
  default     = "10.20.0.0/16"
}

variable "aks_subnet_prefix" {
  description = "AKS node subnet. Nodes only: Azure CNI Overlay puts pods in a separate overlay CIDR."
  type        = string
  default     = "10.20.0.0/22"
}

variable "pe_subnet_prefix" {
  description = "Subnet reserved for private endpoints or the M8 runner VM; unused in M1."
  type        = string
  default     = "10.20.8.0/24"
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
}
