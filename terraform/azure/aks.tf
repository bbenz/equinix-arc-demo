# =============================================================================
# AKS member cluster (native Fleet member - no Arc needed).
# Azure CNI Overlay + Cilium with a managed VNet: AKS does not need to be on
# the ExpressRoute path for this demo, so it stays as small as possible.
# =============================================================================
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${local.name_base}-aks"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  dns_prefix          = "${local.name_base}-aks"
  sku_tier            = var.aks_sku_tier

  default_node_pool {
    name                 = "system"
    vm_size              = var.aks_node_vm_size
    node_count           = var.aks_node_count
    auto_scaling_enabled = var.aks_autoscaling_enabled
    min_count            = var.aks_autoscaling_enabled ? var.aks_min_count : null
    max_count            = var.aks_autoscaling_enabled ? var.aks_max_count : null
    os_disk_size_gb      = 30

    # Pinned to the values AKS reports back, so re-plans stay clean
    # (lesson from fleet-manager-arc-demo: omitting these caused drift).
    upgrade_settings {
      drain_timeout_in_minutes      = 0
      max_surge                     = "10%"
      node_soak_duration_in_minutes = 0
    }
  }

  # Required block in azurerm 5.x. Manual = classic node pools (no node
  # auto-provisioning), which keeps the demo cost predictable.
  node_provisioning_profile {
    mode = "Manual"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
  }

  role_based_access_control_enabled = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true

  dynamic "oms_agent" {
    for_each = var.enable_diagnostics ? [1] : []
    content {
      log_analytics_workspace_id = azurerm_log_analytics_workspace.aks[0].id
    }
  }

  tags = local.tags

  lifecycle {
    # Subscription security policy may attach a Defender workspace; don't fight it.
    ignore_changes = [microsoft_defender]
  }
}

resource "azurerm_log_analytics_workspace" "aks" {
  count               = var.enable_diagnostics ? 1 : 0
  name                = "${local.name_base}-logs"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "aks" {
  count                      = var.enable_diagnostics ? 1 : 0
  name                       = "${local.name_base}-aks-diag"
  target_resource_id         = azurerm_kubernetes_cluster.aks.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.aks[0].id

  enabled_log {
    category = "kube-apiserver"
  }
  enabled_log {
    category = "kube-audit"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}
