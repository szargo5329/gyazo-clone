# AKS cluster for M3 (D-007, D-021).
#
# Every role assigned below must be on the ci-apply ABAC allowlist in
# infra/bootstrap/roles.tf, otherwise CI's apply is denied when creating it.

# Control-plane identity. User-assigned (not system-assigned) so its role
# assignments exist before the cluster does, and survive a cluster rebuild.
resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "id-gyazo-aks-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# BYO subnet: the control plane must be able to join NICs/LB to snet-aks.
# Review rule (D-021): Network Contributor only for this UAMI, only at snet-aks/gateway-PIP scope; never RG scope, never api/worker (ABAC can't enforce below RG).
resource "azurerm_role_assignment" "control_plane_subnet" {
  scope                = var.aks_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
}

# The gateway public IP lives outside the node resource group (D-011), so the
# cloud provider needs explicit rights to attach it to the cluster load balancer.
# Scoped to the IP itself. The gateway Service should reference it by name
# (azure-pip-name annotation, a direct GET) rather than by IP (an RG list); see D-021 "Risks".
# Review rule (D-021): Network Contributor only for this UAMI, only at snet-aks/gateway-PIP scope; never RG scope, never api/worker (ABAC can't enforce below RG).
resource "azurerm_role_assignment" "control_plane_gateway_pip" {
  scope                = var.gateway_public_ip_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_kubernetes_cluster" "this" {
  #checkov:skip=CKV_AZURE_115:Public API server restricted by authorized IP ranges (D-007); a private cluster needs a jumpbox/VPN (cost).
  #checkov:skip=CKV_AZURE_117:Disks are encrypted at rest with platform-managed keys; a disk encryption set (CMK) adds Key Vault key management for no demo benefit (D-021).
  #checkov:skip=CKV_AZURE_4:Container Insights/Log Analytics is paid ingestion; observability is self-hosted (D-009).
  #checkov:skip=CKV_AZURE_116:Azure Policy add-on runs extra pods on a single small node; admission control is out of scope for the demo (D-021).
  #checkov:skip=CKV_AZURE_170:Free control-plane tier by design (cost, no SLA needed, D-021).
  #checkov:skip=CKV_AZURE_226:Standard_D2s_v6 has no ephemeral OS disk support (D-013, D-021).
  #checkov:skip=CKV_AZURE_227:Encryption at host needs the EncryptionAtHost subscription feature registered (a subscription change); deferred, platform-managed disk encryption applies (D-021).
  #checkov:skip=CKV_AZURE_232:Single system pool by design (cost, D-021); app pods must schedule on it, so it can't be tainted CriticalAddonsOnly.
  #checkov:skip=CKV_AZURE_7:Network policy engine not chosen yet (TODO(M3) in network_profile); decision pending research, see D-021 open item.
  name                = "aks-gyazo-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  dns_prefix          = "gyazo-${var.env}"

  kubernetes_version        = var.kubernetes_version
  sku_tier                  = "Free"
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  # Workload identity (D-005): pods exchange a projected SA token for an Entra token.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # No static kubeconfig credentials: Entra ID auth + Azure RBAC only. The owner's
  # AKS RBAC Cluster Admin role is granted at RG scope in infra/bootstrap.
  local_account_disabled = true

  # azurerm 5.14 requires tenant_id or admin_group_object_ids; no admin groups
  # (access is via Azure RBAC role assignments only).
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = var.tenant_id
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  # Created locked down. "0.0.0.0/32" is AKS's special value for "only the
  # cluster's own outbound IP", so nobody can reach the API server until the owner
  # runs, outside Terraform:
  #   az aks update -g <rg> -n <cluster> --api-server-authorized-ip-ranges <home-ip>/32
  # The range is ignored below so the owner's IP never lands in this public repo
  # and CI applies never reset it (D-021).
  api_server_access_profile {
    authorized_ip_ranges = ["0.0.0.0/32"]
  }

  # Required block in azurerm 5.x. Manual = classic node pools (no Node Auto
  # Provisioning); default_node_pools = None so no extra NAP pools are created.
  node_provisioning_profile {
    mode               = "Manual"
    default_node_pools = "None"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.control_plane.id]
  }

  # Azure CNI Overlay (D-007). VNet is 10.20.0.0/16; pod 10.244.0.0/16 and
  # service 10.0.0.0/16 overlap neither it nor each other.
  # TODO(M3): choose a network policy engine (network_policy + network_data_plane,
  # e.g. Cilium) after the researcher confirms overlay compatibility; checkov
  # CKV_AZURE_7 is skipped until then.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    outbound_type       = "loadBalancer"
    load_balancer_sku   = "standard"
  }

  # Single autoscaled system pool (D-021). No node_count: the autoscaler owns it.
  # No zones: single-zone demo, and zones can't be changed without a rebuild.
  default_node_pool {
    name                 = "system"
    vm_size              = var.node_vm_size
    os_disk_type         = "Managed" # Dsv6 has no ephemeral OS disk support
    vnet_subnet_id       = var.aks_subnet_id
    auto_scaling_enabled = true
    min_count            = var.node_min_count
    max_count            = var.node_max_count
    max_pods             = 250 # overlay default, set explicitly
    tags                 = var.tags

    upgrade_settings {
      max_surge = "1"
    }
  }

  tags = var.tags

  lifecycle {
    # Managed out of band by the owner (see api_server_access_profile above).
    ignore_changes = [api_server_access_profile[0].authorized_ip_ranges]

    precondition {
      condition     = var.node_min_count <= var.node_max_count
      error_message = "node_min_count must not exceed node_max_count."
    }
  }

  # The control plane needs both grants at create time (subnet join, PIP attach).
  depends_on = [
    azurerm_role_assignment.control_plane_subnet,
    azurerm_role_assignment.control_plane_gateway_pip,
  ]
}

# Image pulls by the kubelet (system-created kubelet identity in the node RG).
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  principal_type       = "ServicePrincipal" # required by the ci-apply ABAC condition
}
