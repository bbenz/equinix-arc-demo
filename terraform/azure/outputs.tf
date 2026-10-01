output "resource_group_name" {
  description = "Resource group for AKS, Fleet Manager, ExpressRoute, the egress proxy and the Arc-connected EKS/Equinix cluster resources."
  value       = azurerm_resource_group.demo.name
}

output "location" {
  description = "Azure region used by this root."
  value       = azurerm_resource_group.demo.location
}

output "tenant_id" {
  description = "Active Entra ID tenant (from the az CLI session used to apply)."
  value       = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  description = "Active Azure subscription (from the az CLI session used to apply)."
  value       = data.azurerm_client_config.current.subscription_id
}

# --- AKS / Fleet -------------------------------------------------------------
output "aks_cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.aks.name
}

output "aks_cluster_id" {
  description = "AKS cluster ARM ID."
  value       = azurerm_kubernetes_cluster.aks.id
}

output "fleet_name" {
  description = "Fleet Manager name."
  value       = azapi_resource.fleet.name
}

output "fleet_id" {
  description = "Fleet Manager ARM ID (with hub cluster)."
  value       = azapi_resource.fleet.id
}

output "arc_resource_group" {
  description = "Resource group for `az connectedk8s connect` (EKS and the Equinix cluster)."
  value       = azurerm_resource_group.demo.name
}

output "kubeconfig_command" {
  description = "Fetches the AKS kubeconfig into the repo-wide 'aks-demo' context (run by scripts/04-apply.ps1)."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.demo.name} --name ${azurerm_kubernetes_cluster.aks.name} --context aks-demo --overwrite-existing"
}

# --- ExpressRoute ------------------------------------------------------------
output "expressroute_enabled" {
  description = "Whether the ExpressRoute path (circuit, gateway, egress proxy) exists."
  value       = var.enable_expressroute
}

output "expressroute_circuit_name" {
  description = "ExpressRoute circuit name (provider: Equinix)."
  value       = var.enable_expressroute ? azurerm_express_route_circuit.equinix[0].name : null
}

output "expressroute_circuit_id" {
  description = "ExpressRoute circuit ARM ID."
  value       = var.enable_expressroute ? azurerm_express_route_circuit.equinix[0].id : null
}

output "expressroute_service_key" {
  description = "Circuit service key handed to Equinix Fabric. Sensitive: scripts pass it to terraform/equinix via a process-scoped TF_VAR env var - it is never printed or written to tfvars."
  value       = var.enable_expressroute ? azurerm_express_route_circuit.equinix[0].service_key : null
  sensitive   = true
}

output "expressroute_peering_location" {
  description = "ExpressRoute peering location (must match the Equinix metro)."
  value       = var.expressroute_peering_location
}

output "expressroute_bandwidth_mbps" {
  description = "Circuit bandwidth - the Equinix Fabric connection is ordered with the same value."
  value       = var.expressroute_bandwidth_mbps
}

output "expressroute_vlan_id" {
  description = "Private peering VLAN ID (= Equinix connection C-tag)."
  value       = var.expressroute_vlan_id
}

output "expressroute_private_peering_enabled" {
  description = "Whether private peering + gateway connection are configured."
  value       = var.enable_expressroute && var.expressroute_private_peering_enabled
}

output "expressroute_gateway_name" {
  description = "ExpressRoute virtual network gateway name."
  value       = var.enable_expressroute ? azurerm_virtual_network_gateway.er[0].name : null
}

output "hub_vnet_cidr" {
  description = "Hub VNet address space advertised to Equinix over private peering."
  value       = var.hub_vnet_cidr
}

# --- Egress proxy --------------------------------------------------------------
output "egress_proxy_vm_name" {
  description = "Egress proxy VM name (managed via `az vm run-command`, no SSH)."
  value       = var.enable_expressroute ? azurerm_linux_virtual_machine.proxy[0].name : null
}

output "egress_proxy_private_ip" {
  description = "Private IP of the Squid explicit proxy - reachable from Equinix over ExpressRoute."
  value       = var.enable_expressroute ? azurerm_network_interface.proxy[0].private_ip_address : null
}

output "egress_proxy_url" {
  description = "Value for --proxy-https/--proxy-http (az connectedk8s connect) and HTTP(S)_PROXY on the Equinix K3s nodes."
  value       = var.enable_expressroute ? "http://${azurerm_network_interface.proxy[0].private_ip_address}:${var.proxy_port}" : null
}

output "egress_proxy_allowed_domains" {
  description = "Effective Squid allowlist."
  value       = local.proxy_allowed_domains
}

output "storefront_public_url" {
  description = "Equinix storefront published through the hub over ExpressRoute (null unless storefront_allowed_cidrs is set)."
  value       = var.enable_expressroute && length(var.storefront_allowed_cidrs) > 0 ? "http://${azurerm_public_ip.proxy[0].ip_address}/" : null
}

# --- Optional private access ---------------------------------------------------
output "private_acr_login_server" {
  description = "Private ACR login server (null unless enable_private_acr)."
  value       = var.enable_expressroute && var.enable_private_acr ? azurerm_container_registry.private[0].login_server : null
}

output "private_acr_name" {
  description = "Private ACR name (null unless enable_private_acr)."
  value       = var.enable_expressroute && var.enable_private_acr ? azurerm_container_registry.private[0].name : null
}

output "dns_resolver_inbound_ip" {
  description = "Conditional-forwarder target for privatelink.* zones at the Equinix site (null unless enable_dns_private_resolver)."
  value       = var.enable_expressroute && var.enable_dns_private_resolver ? azurerm_private_dns_resolver_inbound_endpoint.hub[0].ip_configurations[0].private_ip_address : null
}

# NOTE: the AKS kube_config and the proxy VM's generated SSH key exist in
# Terraform state (unavoidable, documented in docs/AUTHENTICATION-AND-PERMISSIONS.md)
# but are deliberately NOT re-exposed as outputs.
