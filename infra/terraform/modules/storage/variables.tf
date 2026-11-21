variable "env" {
  description = "Environment name used in resource names (e.g. dev)."
  type        = string
}

variable "suffix" {
  description = "Random lowercase alphanumeric suffix that makes the globally unique account name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.suffix))
    error_message = "The suffix must be 3-10 lowercase letters/digits."
  }
}

variable "resource_group_name" {
  description = "Resource group to create the storage account in."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "soft_delete_days" {
  description = "Retention in days for blob and container soft delete."
  type        = number
  default     = 7

  validation {
    condition     = var.soft_delete_days >= 1 && var.soft_delete_days <= 365
    error_message = "The soft_delete_days value must be between 1 and 365."
  }
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
}
