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

variable "github_subject_repo" {
  description = <<-EOT
    Repository part of the OIDC `sub` claim GitHub actually sends: `<owner>@<owner_id>/<repo>@<repo_id>`.
    GitHub embeds immutable numeric IDs, so a deleted-and-recreated repo with the same name can't
    reuse this trust. Look up the IDs with: gh api repos/<owner>/<repo> -q '.owner.id, .id'
  EOT
  type        = string
  default     = "szargo5329@63083007/gyazo-clone@1460876206"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+@[0-9]+/[A-Za-z0-9._-]+@[0-9]+$", var.github_subject_repo))
    error_message = "The github_subject_repo value must look like <owner>@<owner_id>/<repo>@<repo_id>."
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
