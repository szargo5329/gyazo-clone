# Role assignments for the CI identities and the human operator.
# Data-plane storage roles are required throughout because shared keys are disabled:
# without an access key, Terraform has to read/write blobs, queues and tables
# (including the state blob) with Entra ID tokens, which need explicit data roles.

locals {
  # Roles ci-apply may assign/delete in rg-<env> (the main config's identities need
  # exactly these). Anything else, including Owner, Contributor, User Access
  # Administrator and RBAC Administrator, is denied by the ABAC condition below.
  #
  # Network Contributor is the one non-data-plane entry: the AKS control-plane
  # user-assigned identity needs it on snet-aks and on the ingress public IP (D-011),
  # and AKS only creates those assignments itself when driven by the az CLI.
  # Trade-off: ci-apply can now grant network write (no data access) to any service
  # principal in rg-<env>. It still can't grant to the CI identities or to users, and
  # every apply stays behind the human-approved `apply` environment.
  delegable_role_names = toset([
    "Network Contributor",
    "Storage Blob Data Contributor",
    "Storage Queue Data Message Sender",
    "Storage Queue Data Message Processor",
    "Storage Table Data Contributor",
    "Storage Blob Delegator",
    "Key Vault Secrets User",
    "AcrPull",
  ])

  delegable_role_guids = join(", ", sort([
    for name in local.delegable_role_names : data.azurerm_role_definition.delegable[name].role_definition_id
  ]))

  # Constrained-delegation condition (condition_version 2.0), in the documented format:
  # writes are checked against the requested role, deletes against the existing one.
  # Set operators matter: for one value X vs {a,b}, ForAnyOfAnyValues:GuidEquals = "X is one of",
  # ForAnyOfAllValues:GuidNotEquals = "X is none of" (Microsoft's documented exclusion form).
  # ForAnyOfAnyValues:GuidNotEquals would be "X != a OR X != b", which is always true. Caught in review.
  rbac_admin_condition = <<-EOT
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
     )
     OR
     (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.delegable_role_guids}}
      AND
      @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}
      AND
      @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAllValues:GuidNotEquals {${azurerm_user_assigned_identity.ci_apply.principal_id}, ${azurerm_user_assigned_identity.ci_plan.principal_id}}
     )
    )
    AND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
     )
     OR
     (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.delegable_role_guids}}
     )
    )
  EOT
}

# Built-in role GUIDs are looked up by name, not hardcoded.
data "azurerm_role_definition" "delegable" {
  for_each = local.delegable_role_names
  name     = each.value
  scope    = data.azurerm_subscription.current.id
}

# ---------------------------------------------------------------------------
# Human operator: needs data-plane access to the state container to run the main
# config locally (`use_azuread_auth = true`). Owner on the subscription does NOT
# include blob data actions.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "human_state_blob_contributor" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
  description          = "Operator who ran bootstrap: read/write/lease the Terraform state blob."
}

# AKS runs with local accounts disabled and Azure RBAC for Kubernetes authorization,
# so the operator needs a Kubernetes RBAC role to use kubectl. Scoped to rg-<env> so it
# survives cluster rebuilds. Granted here because ci-apply can't: the ABAC condition
# only allows service principals as assignees.
resource "azurerm_role_assignment" "human_aks_rbac_cluster_admin" {
  scope                = azurerm_resource_group.env.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
  description          = "Operator who ran bootstrap: kubectl cluster-admin on AKS clusters in rg-<env> (Azure RBAC, local accounts off)."
}

# ---------------------------------------------------------------------------
# ci-plan: read-only. Runs on PR code (D-012), so the worst it can do is read.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "ci_plan_reader" {
  scope                = azurerm_resource_group.env.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "ci_plan_state_reader" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
  principal_type       = "ServicePrincipal"
}

# Deliberately NO data-plane roles on rg-<env>: the app's containers, queues and tables
# are created via `storage_account_id`, which azurerm v5 manages through the ARM control
# plane, so Reader is enough to refresh them. Granting Storage Blob Data Reader here would
# let PR-controlled code read users' images. If a CI plan fails with a data-plane 403,
# add the narrowest role that fixes it and record why.

# ---------------------------------------------------------------------------
# ci-apply: write access to rg-<env> only, behind the protected `apply` environment.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "ci_apply_contributor" {
  scope                = azurerm_resource_group.env.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_apply.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "ci_apply_state_contributor" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_apply.principal_id
  principal_type       = "ServicePrincipal"
}

# No data-plane roles for ci-apply either: containers/queues/tables are ARM resources
# (covered by Contributor), and no Key Vault secrets are managed in Terraform. CI never
# needs to read image bytes or secret values. Add a role only if an apply proves it's needed.

# Lets the main config create the workload identities' role assignments, but only
# for the allowlisted data-plane roles, only to service principals, and never to the CI
# identities themselves (no self-grant of image/secret access). It cannot grant
# Owner/Contributor/RBAC admin. This *narrows* CI's power rather than eliminating it:
# Contributor can still create resources that carry their own identity. Reviewed by a human
# at every apply via the `apply` environment.
resource "azurerm_role_assignment" "ci_apply_rbac_admin" {
  scope                = azurerm_resource_group.env.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.ci_apply.principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = trimspace(local.rbac_admin_condition) # no trailing newline → no perpetual diff
  description          = "Constrained delegation: assign/delete only allowlisted data-plane roles."

  lifecycle {
    # The condition must contain bare role GUIDs, not full role definition resource IDs.
    precondition {
      condition = alltrue([
        for name in local.delegable_role_names :
        can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", data.azurerm_role_definition.delegable[name].role_definition_id))
      ])
      error_message = "Every allowlisted role must resolve to a bare role definition GUID for the ABAC condition."
    }
  }
}
