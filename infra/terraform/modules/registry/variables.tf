variable "env" {
  description = "Environment name used in resource names (e.g. dev)."
  type        = string
}

variable "suffix" {
  description = "Random lowercase alphanumeric suffix that makes the globally unique registry name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.suffix))
    error_message = "The suffix must be 3-10 lowercase letters/digits (ACR names are alphanumeric only)."
  }
}

variable "resource_group_name" {
  description = "Resource group to create the registry in."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
}
