# Non-secret defaults live here instead of a terraform.tfvars, because the repo's
# secret-file hook only allowlists infra/terraform/envs/*/terraform.tfvars.

variable "location" {
  description = "Azure region for the platform and dev resource groups."
  type        = string
  default     = "centralus"
}

variable "owner" {
  description = "Value of the required `owner` tag."
  type        = string
  default     = "szargo5329"
}

variable "github_repo" {
  description = "GitHub repository (`<owner>/<name>`) trusted by the CI federated identity credentials."
  type        = string
  default     = "szargo5329/gyazo-clone"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repo))
    error_message = "The github_repo value must look like <owner>/<name>."
  }
}

variable "env" {
  description = "Workload environment whose resource group bootstrap creates and grants CI access to."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev"], var.env)
    error_message = "Only the dev environment exists."
  }
}
