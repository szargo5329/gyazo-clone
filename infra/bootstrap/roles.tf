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
  # Trade-off: ci-apply can now grant network write (no data-plane or role-assignment
  # rights; can alter network paths) to any service principal in rg-<env>. It still
  # can't grant to the CI identities or to users, and every apply stays behind the
  # human-approved `apply` environment.
  # Review rule (ABAC can't enforce scope): Network Contributor is for the AKS
  # control-plane UAMI only, scoped to snet-aks and the gateway PIP. Never rg scope,
  # never the api/worker identities.
  #
  # The custom role "gyazo AKS public IP reader (<env>)" (defined below, D-029) is also
  # allowlisted: the cloud provider lists public IPs in the PIP's resource group, so the
  # control-plane UAMI needs publicIPAddresses/read at rg scope. Read-only, one action.
  # ABAC can't pin it to that UAMI (it is created by the main config, so its principal ID
  # isn't known here and changes on rebuild). Review rule: assign it only to the AKS
  # control-plane UAMI, only at rg-<env> scope.
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

  # Built-in roles (looked up by name) plus the custom roles defined in this file that
  # the main config assigns.
  delegable_role_guids = join(", ", sort(concat(
    [for name in local.delegable_role_names : data.azurerm_role_definition.delegable[name].role_definition_id],
    [azurerm_role_definition.aks_pip_reader.role_definition_id],
  )))

  # Constrained-delegation condition (condition_version 2.0), in the documented format:
  # writes are checked against the requested role, deletes against the existing one.
  # Set operators matter: for one value X vs {a,b}, ForAnyOfAnyValues:GuidEquals = "X is one of",
  # ForAnyOfAllValues:GuidNotEquals = "X is none of" (Microsoft's documented exclusion form).
  # ForAnyOfAnyValues:GuidNotEquals would be "X != a OR X != b", which is always true. Caught in review.
  # The PrincipalId exclusion covers every CI identity (plan, apply, push, aks-power), so
  # ci-apply can never grant an allowlisted role to any of them. Add new CI identities here.
  # Deletes have no PrincipalId check (the documented delete form only constrains the role):
  # ci-apply can delete an allowlisted-role assignment from anyone, but none of the CI
  # identities' assignments in rg-<env> use allowlisted roles, so it can't strip them.
  # Invariant: if a CI identity is ever given an allowlisted role in rg-<env> (e.g. AcrPull),
  # ci-apply could delete that assignment. Revisit this condition before doing so.
  ci_principal_ids = join(", ", [
    azurerm_user_assigned_identity.ci_apply.principal_id,
    azurerm_user_assigned_identity.ci_plan.principal_id,
    azurerm_user_assigned_identity.ci_push.principal_id,
    azurerm_user_assigned_identity.ci_aks_power.principal_id,
  ])

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
      @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAllValues:GuidNotEquals {${local.ci_principal_ids}}
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
  description          = "Operator who ran bootstrap: kubectl cluster-admin on AKS clusters in this env resource group (Azure RBAC, local accounts off)."
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

# azurerm's refresh of azurerm_kubernetes_cluster calls listClusterUserCredential, a POST
# action that Reader lacks, so without this every PR plan would 403 once the cluster exists.
# With Azure RBAC enabled it only returns a kubeconfig stub and gives no in-cluster rights.
# RG scope because the cluster doesn't exist at bootstrap time and must survive rebuilds.
# Design-verified; the first CI plan after the cluster exists proves it.
resource "azurerm_role_assignment" "ci_plan_aks_cluster_user" {
  scope                = azurerm_resource_group.env.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
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
# for the allowlisted roles, only to service principals, and never to any CI
# identity (plan, apply, push, aks-power: no self-grant of image/secret access). It cannot grant
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
  description          = "Constrained delegation: assign/delete only allowlisted roles."

  lifecycle {
    # The condition must contain bare role GUIDs, not full role definition resource IDs.
    precondition {
      condition = alltrue([
        for name in local.delegable_role_names :
        can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", data.azurerm_role_definition.delegable[name].role_definition_id))
      ])
      error_message = "Every allowlisted built-in role must resolve to a bare role definition GUID for the ABAC condition."
    }

    precondition {
      condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", azurerm_role_definition.aks_pip_reader.role_definition_id))
      error_message = "The custom public IP reader role must resolve to a bare role definition GUID for the ABAC condition."
    }
  }
}

# ---------------------------------------------------------------------------
# ci-push: push app images to ACR, behind the `push` environment (main only). D-024.
# ---------------------------------------------------------------------------

# AcrPush = pull + push, no delete. It is the documented CI push role while the
# registry uses LegacyRegistryPermissions (D-021); the Repository Writer roles only
# apply in ABAC repository-permissions mode.
# Scope trade-off: rg-<env>, not the registry. Bootstrap runs before the main config
# creates the ACR on a rebuild, so a registry-scoped data lookup would break ordering.
# Review rule: only one registry may exist in rg-gyazo-<env>; a second one would be
# pushable by CI.
# Unverified: `az acr login` may also need a control-plane read on the registry. Don't
# add a role for it until the first live push run proves it (record the result in D-024).
resource "azurerm_role_assignment" "ci_push_acr_push" {
  scope                = azurerm_resource_group.env.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.ci_push.principal_id
  principal_type       = "ServicePrincipal"
  description          = "CI image push from main: pull and push to the single registry in this env resource group."
}

# ---------------------------------------------------------------------------
# ci-aks-power: nightly AKS stop (and manual start), behind the `aks-power`
# environment (main only). D-025.
# ---------------------------------------------------------------------------

# No built-in role is this narrow: Azure Kubernetes Service Contributor Role also allows
# update and delete of the cluster. Read is needed so `az aks stop/start` can look the
# cluster up. No data actions, so no in-cluster or credential access.
# `Microsoft.Resources/subscriptions/operationresults/read` may be needed for az's
# long-running-operation polling; add it only if the live run returns 403 (untested).
resource "azurerm_role_definition" "aks_start_stop" {
  name        = "gyazo AKS start-stop (${var.env})"
  scope       = azurerm_resource_group.env.id
  description = "Read, start and stop AKS clusters in rg-gyazo-${var.env}. No update, delete or credential access."

  permissions {
    actions = [
      "Microsoft.ContainerService/managedClusters/read",
      "Microsoft.ContainerService/managedClusters/start/action",
      "Microsoft.ContainerService/managedClusters/stop/action",
    ]
    not_actions = []
  }

  assignable_scopes = [azurerm_resource_group.env.id]
}

# RG scope so the grant survives a cluster rebuild; it covers only clusters in rg-<env>.
resource "azurerm_role_assignment" "ci_aks_power_start_stop" {
  scope              = azurerm_resource_group.env.id
  role_definition_id = azurerm_role_definition.aks_start_stop.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.ci_aks_power.principal_id
  principal_type     = "ServicePrincipal"
  description        = "Scheduled AKS stop and manual start for clusters in this env resource group."
}

# ---------------------------------------------------------------------------
# AKS control-plane identity: read public IPs in rg-<env> (D-029). Assigned by the
# main config (modules/aks), so it is on the ci-apply allowlist above.
# ---------------------------------------------------------------------------

# cloud-provider-azure lists public IPs in the PIP's resource group
# (azure-load-balancer-resource-group) when reconciling a LoadBalancer Service, even
# when the IP is referenced by name, so the PIP-scoped Network Contributor grant alone
# 403s on the list. No built-in role is this narrow: Reader reads everything in the RG,
# Network Contributor at RG scope can change the VNet and NSGs.
resource "azurerm_role_definition" "aks_pip_reader" {
  name        = "gyazo AKS public IP reader (${var.env})"
  scope       = azurerm_resource_group.env.id
  description = "Read (get/list) public IP addresses in rg-gyazo-${var.env}. No write, delete or join."

  permissions {
    actions = [
      "Microsoft.Network/publicIPAddresses/read",
    ]
    not_actions = []
  }

  assignable_scopes = [azurerm_resource_group.env.id]
}
