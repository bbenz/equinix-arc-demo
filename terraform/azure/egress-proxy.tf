# =============================================================================
# Egress proxy VM (hub VNet). Gives the Equinix-hosted cluster - which has NO
# internet egress of its own - a path to Azure Arc, the Fleet hub and the demo
# image registries that leaves the Equinix site ONLY over ExpressRoute:
#
#   Equinix node -> Arc Proxy pod -> (ExpressRoute private peering) ->
#   Squid in this VM -> Azure Arc gateway / ARM / Entra ID / MCR (Microsoft backbone)
#
# Production alternative: Azure Firewall with explicit proxy, or your
# existing enterprise proxy in Azure. See docs/NETWORKING-EXPRESSROUTE.md.
# =============================================================================
resource "tls_private_key" "proxy" {
  count     = var.enable_expressroute ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_public_ip" "proxy" {
  count               = var.enable_expressroute ? 1 : 0
  name                = "${local.name_base}-proxy-pip"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "proxy" {
  count               = var.enable_expressroute ? 1 : 0
  name                = "${local.name_base}-proxy-nic"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.proxy[0].id
    private_ip_address_allocation = "Static"
    # Stable address: it is baked into the Arc agents' proxy settings
    # (az connectedk8s connect --proxy-https) and the K3s service env.
    private_ip_address   = cidrhost(var.proxy_subnet_cidr, 10)
    public_ip_address_id = azurerm_public_ip.proxy[0].id
  }
}

resource "azurerm_linux_virtual_machine" "proxy" {
  count                           = var.enable_expressroute ? 1 : 0
  name                            = "${local.name_base}-egress-proxy"
  location                        = azurerm_resource_group.demo.location
  resource_group_name             = azurerm_resource_group.demo.name
  size                            = var.proxy_vm_size
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.proxy[0].id]
  tags                            = local.tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.proxy[0].public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  boot_diagnostics {}
}

resource "azurerm_virtual_machine_run_command" "configure_proxy" {
  count              = var.enable_expressroute ? 1 : 0
  name               = "configure-egress-proxy"
  location           = azurerm_resource_group.demo.location
  virtual_machine_id = azurerm_linux_virtual_machine.proxy[0].id
  tags               = local.tags

  source {
    script = templatefile("${path.module}/templates/configure-egress-proxy.sh.tftpl", {
      allowed_domains      = local.proxy_allowed_domains
      proxy_port           = var.proxy_port
      onprem_prefixes      = var.equinix_onprem_prefixes
      hub_vnet_cidr        = var.hub_vnet_cidr
      storefront_upstreams = var.equinix_storefront_upstreams
    })
  }
}
