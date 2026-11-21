variable "env" {
  description = "Environment name used in resource names (e.g. dev)."
  type        = string
}

variable "suffix" {
  description = "Random lowercase alphanumeric suffix that makes the globally unique vault name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.suffix))
    error_message = "The suffix must be 3-10 lowercase letters/digits (vault names are max 24 chars)."
  }
}

variable "resource_group_name" {
  description = "Resource group to create the vault in."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tenant_id" {
  description = "Entra tenant ID that authenticates requests to the vault."
  type        = string
}

variable "soft_delete_retention_days" {
  description = "Days a deleted vault/secret stays recoverable (7-90)."
  type        = number
  default     = 7

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "The soft_delete_retention_days value must be between 7 and 90."
  }
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
}
