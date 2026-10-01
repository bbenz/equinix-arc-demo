# =============================================================================
# Hub VNet - the network the ExpressRoute gateway advertises to Equinix.
# Only created when enable_expressroute = true. AKS keeps its own managed VNet
# (it doesn't need to be on the private path for this demo).
# =============================================================================
resource "azurerm_virtual_network" "hub" {
  count               = var.enable_expressroute ? 1 : 0
  name                = "${local.name_base}-hub-vnet"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  address_space       = [var.hub_vnet_cidr]
  tags                = local.tags
}

# GatewaySubnet: name is mandatory; NSGs and 0.0.0.0/0 UDRs are NOT supported
# on this subnet (https://learn.microsoft.com/azure/expressroute/expressroute-about-virtual-network-gateways).
resource "azurerm_subnet" "gateway" {
  count                = var.enable_expressroute ? 1 : 0
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.hub[0].name
  address_prefixes     = [var.gateway_subnet_cidr]
}

# Private subnet (no implicit default outbound access). The proxy VM gets
# explicit outbound connectivity from its own Standard public IP.
resource "azurerm_subnet" "proxy" {
  count                           = var.enable_expressroute ? 1 : 0
  name                            = "snet-egress-proxy"
  resource_group_name             = azurerm_resource_group.demo.name
  virtual_network_name            = azurerm_virtual_network.hub[0].name
  address_prefixes                = [var.proxy_subnet_cidr]
  default_outbound_access_enabled = false
}

resource "azurerm_network_security_group" "proxy" {
  count               = var.enable_expressroute ? 1 : 0
  name                = "${local.name_base}-proxy-nsg"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = local.tags
}

# Explicit proxy port: only from the Equinix prefixes learned over
# ExpressRoute (and the hub itself, for in-VNet testing).
resource "azurerm_network_security_rule" "proxy_from_equinix" {
  count                       = var.enable_expressroute ? 1 : 0
  name                        = "allow-proxy-from-equinix"
  description                 = "Equinix-hosted cluster to Squid explicit proxy over ExpressRoute private peering"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(var.proxy_port)
  source_address_prefixes     = concat(var.equinix_onprem_prefixes, [var.hub_vnet_cidr])
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.demo.name
  network_security_group_name = azurerm_network_security_group.proxy[0].name
}

# Optional: publish the Equinix storefront (nginx on the proxy VM, forwarding
# over ExpressRoute) to the presenter's IP only.
resource "azurerm_network_security_rule" "storefront_from_presenter" {
  count                       = var.enable_expressroute && length(var.storefront_allowed_cidrs) > 0 ? 1 : 0
  name                        = "allow-storefront-from-presenter"
  description                 = "Presenter browser to nginx reverse proxy for the Equinix storefront"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefixes     = var.storefront_allowed_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.demo.name
  network_security_group_name = azurerm_network_security_group.proxy[0].name
}

# Everything not allowed above is denied. That includes the VirtualNetwork
# service tag: it spans the hub AND the ExpressRoute-connected Equinix prefixes,
# so Azure's default AllowVnetInBound rule would otherwise expose SSH and any
# other port to the cage. The VM is managed with Run Command, which only needs
# outbound VM-agent traffic.
resource "azurerm_network_security_rule" "deny_all_other_inbound" {
  count                       = var.enable_expressroute ? 1 : 0
  name                        = "deny-all-other-inbound"
  description                 = "Only the proxy port (Equinix and hub) and the optional storefront port (presenter) are allowed in. No SSH from anywhere."
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.demo.name
  network_security_group_name = azurerm_network_security_group.proxy[0].name
}

resource "azurerm_subnet_network_security_group_association" "proxy" {
  count                     = var.enable_expressroute ? 1 : 0
  subnet_id                 = azurerm_subnet.proxy[0].id
  network_security_group_id = azurerm_network_security_group.proxy[0].id
}

# Optional subnets for the "Private Link" extras.
resource "azurerm_subnet" "dns_inbound" {
  count                           = var.enable_expressroute && var.enable_dns_private_resolver ? 1 : 0
  name                            = "snet-dns-inbound"
  resource_group_name             = azurerm_resource_group.demo.name
  virtual_network_name            = azurerm_virtual_network.hub[0].name
  address_prefixes                = [var.dns_inbound_subnet_cidr]
  default_outbound_access_enabled = false

  delegation {
    name = "dns-resolver"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  count                           = var.enable_expressroute && var.enable_private_acr ? 1 : 0
  name                            = "snet-private-endpoints"
  resource_group_name             = azurerm_resource_group.demo.name
  virtual_network_name            = azurerm_virtual_network.hub[0].name
  address_prefixes                = [var.private_endpoint_subnet_cidr]
  default_outbound_access_enabled = false
}
