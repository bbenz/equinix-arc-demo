# =============================================================================
# Optional "Private Link" extras, from the original Equinix demo plan:
#   - enable_private_acr: Premium ACR with public access DISABLED, reachable
#     only via a private endpoint in the hub VNet. Equinix nodes pull through
#     the egress proxy, which resolves <acr>.azurecr.io to the private endpoint
#     because privatelink.azurecr.io is linked to the hub VNet - so image pulls
#     never touch the public internet. Anonymous pull = no credentials on nodes.
#   - enable_dns_private_resolver: inbound endpoint the Equinix site's DNS can
#     conditionally forward privatelink.* zones to (routed, proxy-less pattern).
# =============================================================================
locals {
  acr_suffix = substr(md5("${data.azurerm_client_config.current.subscription_id}/${local.name_base}"), 0, 6)
}

resource "azurerm_container_registry" "private" {
  count                         = var.enable_expressroute && var.enable_private_acr ? 1 : 0
  name                          = "${var.name_prefix}${var.environment}${local.acr_suffix}"
  resource_group_name           = azurerm_resource_group.demo.name
  location                      = azurerm_resource_group.demo.location
  sku                           = "Premium"
  admin_enabled                 = false
  anonymous_pull_enabled        = true
  public_network_access_enabled = false
  # Lets `az acr import` (a trusted Azure service operation) seed images even
  # though public network access is disabled.
  network_rule_bypass_option = "AzureServices"
  tags                       = local.tags
}

resource "azurerm_private_dns_zone" "acr" {
  count               = var.enable_expressroute && var.enable_private_acr ? 1 : 0
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.demo.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  count               = var.enable_expressroute && var.enable_private_acr ? 1 : 0
  name                = "hub-vnet"
  private_dns_zone_id = azurerm_private_dns_zone.acr[0].id
  virtual_network_id  = azurerm_virtual_network.hub[0].id
  tags                = local.tags
}

resource "azurerm_private_endpoint" "acr" {
  count               = var.enable_expressroute && var.enable_private_acr ? 1 : 0
  name                = "${local.name_base}-acr-pe"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  subnet_id           = azurerm_subnet.private_endpoints[0].id
  tags                = local.tags

  private_service_connection {
    name                           = "acr"
    private_connection_resource_id = azurerm_container_registry.private[0].id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "acr"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr[0].id]
  }
}

resource "azurerm_private_dns_resolver" "hub" {
  count               = var.enable_expressroute && var.enable_dns_private_resolver ? 1 : 0
  name                = "${local.name_base}-dnsresolver"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  virtual_network_id  = azurerm_virtual_network.hub[0].id
  tags                = local.tags
}

# Inbound endpoint only. Do NOT add an outbound endpoint with wildcard
# forwarding rules to a VNet that hosts an ExpressRoute gateway.
resource "azurerm_private_dns_resolver_inbound_endpoint" "hub" {
  count                   = var.enable_expressroute && var.enable_dns_private_resolver ? 1 : 0
  name                    = "inbound"
  private_dns_resolver_id = azurerm_private_dns_resolver.hub[0].id
  location                = azurerm_resource_group.demo.location
  tags                    = local.tags

  ip_configurations {
    subnet_id                    = azurerm_subnet.dns_inbound[0].id
    private_ip_allocation_method = "Static"
    private_ip_address           = cidrhost(var.dns_inbound_subnet_cidr, 4)
  }
}
