# =============================================================================
# ExpressRoute: circuit (provider = Equinix) -> Equinix Fabric connection
# (terraform/equinix) -> private peering -> gateway connection.
#
# Order matters and spans two roots, so it is driven by scripts/05-connect-expressroute.ps1:
#   1. This root creates the circuit + gateway. The circuit's service key is
#      handed to terraform/equinix (never printed, never written to tfvars).
#   2. terraform/equinix orders the Fabric connection(s); Equinix + Microsoft
#      provision the circuit (serviceProviderProvisioningState -> Provisioned).
#   3. This root is re-applied with expressroute_private_peering_enabled = true,
#      which creates private peering and links the circuit to the gateway.
#
# BILLING: an ExpressRoute circuit bills from the moment its service key is
# issued (i.e. when this resource is created), not when Equinix provisions it.
# =============================================================================
resource "azurerm_express_route_circuit" "equinix" {
  count                    = var.enable_expressroute ? 1 : 0
  name                     = "${local.name_base}-er-equinix-${lower(replace(var.expressroute_peering_location, " ", ""))}"
  resource_group_name      = azurerm_resource_group.demo.name
  location                 = azurerm_resource_group.demo.location
  service_provider_name    = "Equinix"
  peering_location         = var.expressroute_peering_location
  bandwidth_in_mbps        = var.expressroute_bandwidth_mbps
  allow_classic_operations = false

  sku {
    tier   = var.expressroute_sku_tier
    family = var.expressroute_sku_family
  }

  tags = local.tags
}

# ExpressRoute virtual network gateway. Creation typically takes 30-45
# minutes - run scripts/04-apply.ps1 well before rehearsal. No public IP
# resource is supplied: Azure now auto-assigns and manages the gateway's
# management IP (always zone-redundant).
resource "azurerm_virtual_network_gateway" "er" {
  count               = var.enable_expressroute ? 1 : 0
  name                = "${local.name_base}-ergw"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  type                = "ExpressRoute"
  sku                 = var.expressroute_gateway_sku
  minimum_scale_unit  = var.expressroute_gateway_sku == "ErGwScale" ? var.expressroute_gateway_scale_units : null
  maximum_scale_unit  = var.expressroute_gateway_sku == "ErGwScale" ? var.expressroute_gateway_scale_units : null

  ip_configuration {
    name                          = "default"
    subnet_id                     = azurerm_subnet.gateway[0].id
    private_ip_address_allocation = "Dynamic"
  }

  tags = local.tags
}

# Azure private peering. Your edge router (port origin) or the Fabric Cloud
# Router (cloud_router origin) takes the FIRST usable IP of each /30;
# Microsoft's MSEE routers take the SECOND. Microsoft's ASN is 12076.
resource "azurerm_express_route_circuit_peering" "private" {
  count                         = var.enable_expressroute && var.expressroute_private_peering_enabled ? 1 : 0
  peering_type                  = "AzurePrivatePeering"
  express_route_circuit_name    = azurerm_express_route_circuit.equinix[0].name
  resource_group_name           = azurerm_resource_group.demo.name
  peer_asn                      = var.expressroute_peer_asn
  primary_peer_address_prefix   = var.expressroute_primary_peer_prefix
  secondary_peer_address_prefix = var.expressroute_secondary_peer_prefix
  vlan_id                       = var.expressroute_vlan_id
  ipv4_enabled                  = true
}

resource "azurerm_virtual_network_gateway_connection" "er" {
  count                      = var.enable_expressroute && var.expressroute_private_peering_enabled ? 1 : 0
  name                       = "${local.name_base}-ergw-to-equinix"
  location                   = azurerm_resource_group.demo.location
  resource_group_name        = azurerm_resource_group.demo.name
  type                       = "ExpressRoute"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.er[0].id
  express_route_circuit_id   = azurerm_express_route_circuit.equinix[0].id
  routing_weight             = 0
  tags                       = local.tags

  depends_on = [azurerm_express_route_circuit_peering.private]
}
