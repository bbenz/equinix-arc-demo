# =============================================================================
# Fleet Manager WITH a hub cluster.
# azurerm_kubernetes_fleet_manager can only create a hub-less fleet, but
# ClusterResourcePlacement / ResourceOverride (this demo's entire mechanism)
# need a hub - so azapi is used for this one resource, pinned to the GA API.
# =============================================================================
resource "azapi_resource" "fleet" {
  type      = "Microsoft.ContainerService/fleets@2025-03-01"
  name      = "${local.name_base}-fleet"
  location  = azurerm_resource_group.demo.location
  parent_id = azurerm_resource_group.demo.id
  tags      = local.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      hubProfile = {
        dnsPrefix = "${local.name_base}-fleet"
        agentProfile = {
          vmSize = var.fleet_hub_vm_size
        }
        # Public hub API server (same as fleet-manager-arc-demo). A private
        # fleet is possible - Arc members must then use Arc gateway, which the
        # Equinix member already does - but it needs a jump box for kubectl.
        apiServerAccessProfile = {
          enablePrivateCluster  = false
          enableVnetIntegration = false
        }
      }
    }
  }

  schema_validation_enabled = true
  response_export_values    = ["*"]
}

# AKS joins Fleet natively. EKS and the Equinix cluster join later through
# their Arc connectedCluster resources (scripts/07-join-fleet.ps1), which also
# (re)applies the member labels to all three members in one consistent schema.
resource "azurerm_kubernetes_fleet_member" "aks" {
  name                  = "aks-demo"
  kubernetes_fleet_id   = azapi_resource.fleet.id
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  group                 = "azure"
}
