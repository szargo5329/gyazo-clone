# Role assignments for the CI identities and the human operator.
# Data-plane storage roles are required throughout because shared keys are disabled:
# without an access key, Terraform has to read/write blobs, queues and tables
# (including the state blob) with Entra ID tokens, which need explicit data roles.

locals {
  # Roles ci-apply may assign/delete in rg-<env> (the main config's workload identities
  # need exactly these). Anything else, including Owner, Contributor, User Access
  # Administrator and RBAC Administrator, is denied by the ABAC condition below.
  delegable_role_names = toset([
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
# for the allowlisted data-plane roles above. ci-apply cannot grant itself or anyone
# else Owner/Contributor/RBAC admin, and cannot delete its own assignments.
resource "azurerm_role_assignment" "ci_apply_rbac_admin" {
  scope                = azurerm_resource_group.env.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.ci_apply.principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = local.rbac_admin_condition
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
