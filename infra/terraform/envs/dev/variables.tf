variable "location" {
  description = "Azure region (must match the region bootstrap created rg-gyazo-<env> in)."
  type        = string
}

variable "env" {
  description = "Environment name used in resource names and the env tag."
  type        = string

  validation {
    condition     = contains(["dev"], var.env)
    error_message = "Only the dev environment exists."
  }
}

variable "owner" {
  description = "Value of the required `owner` tag."
  type        = string

  validation {
    condition     = length(var.owner) > 0
    error_message = "The owner value must not be empty."
  }
}

variable "github_repo" {
  description = "GitHub repository (`<owner>/<name>`), recorded as a tag for traceability."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repo))
    error_message = "The github_repo value must look like <owner>/<name>."
  }
}
