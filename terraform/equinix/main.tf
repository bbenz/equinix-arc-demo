locals {
  name_base = "${var.name_prefix}-${var.environment}"

  is_port    = var.fabric_origin == "port"
  is_router  = var.fabric_origin == "cloud_router"
  is_token   = var.fabric_origin == "service_token"
  conn_type  = local.is_router ? "IP_VC" : "EVPL_VC"
  create_fcr = local.is_router && var.create_cloud_router

  cloud_router_uuid = local.is_router ? try(coalesce(one(equinix_fabric_cloud_router.demo[*].id), var.cloud_router_uuid), null) : null
  cloud_router_asn = local.is_router ? one(concat(
    equinix_fabric_cloud_router.demo[*].equinix_asn,
    data.equinix_fabric_cloud_router.existing[*].equinix_asn,
  )) : null

  # Per-leg settings for the redundant pair.
  legs = {
    primary = {
      priority      = "PRIMARY"
      port_uuid     = var.primary_port_uuid
      vlan          = var.primary_vlan_tag
      token_uuid    = var.primary_service_token_uuid
      peer_prefix   = var.expressroute_primary_peer_prefix
      short         = "pri"
      redundancy_ok = true
    }
    secondary = {
      priority      = "SECONDARY"
      port_uuid     = var.secondary_port_uuid
      vlan          = var.secondary_vlan_tag
      token_uuid    = var.secondary_service_token_uuid
      peer_prefix   = var.expressroute_secondary_peer_prefix
      short         = "sec"
      redundancy_ok = var.redundant
    }
  }
}

data "equinix_fabric_cloud_router" "existing" {
  count = local.is_router && !var.create_cloud_router ? 1 : 0
  uuid  = var.cloud_router_uuid
}

# -----------------------------------------------------------------------------
# Optional Fabric Cloud Router (cloud_router origin)
# -----------------------------------------------------------------------------
resource "equinix_fabric_cloud_router" "demo" {
  count = local.create_fcr ? 1 : 0
  name  = "${local.name_base}-fcr"
  type  = "XF_ROUTER"

  lifecycle {
    precondition {
      condition     = var.project_id != null && var.account_number != null
      error_message = "Creating a Fabric Cloud Router requires project_id (EQUINIX_PROJECT_ID) and account_number (EQUINIX_ACCOUNT_NUMBER)."
    }
  }

  notifications {
    type   = "ALL"
    emails = var.notification_emails
  }

  location {
    metro_code = var.metro_code
  }

  package {
    code = var.cloud_router_package
  }

  project {
    project_id = var.project_id
  }

  dynamic "account" {
    for_each = var.account_number != null ? [1] : []
    content {
      account_number = var.account_number
    }
  }

  dynamic "order" {
    for_each = var.purchase_order_number != null ? [1] : []
    content {
      purchase_order_number = var.purchase_order_number
    }
  }
}

# -----------------------------------------------------------------------------
# Equinix Fabric -> Azure ExpressRoute (private peering), primary + secondary.
# The two legs are separate resources because the secondary must reference
# the redundancy group Equinix assigns to the primary.
# -----------------------------------------------------------------------------
resource "equinix_fabric_connection" "azure_primary" {
  name      = "${local.name_base}-azure-er-pri"
  type      = local.conn_type
  bandwidth = var.bandwidth_mbps

  lifecycle {
    precondition {
      condition     = var.expressroute_service_key != null && var.expressroute_service_key != ""
      error_message = "expressroute_service_key is empty. Run scripts/05-connect-expressroute.ps1, which reads it from the Azure circuit and passes it via TF_VAR_expressroute_service_key."
    }
    precondition {
      condition     = !local.is_port || var.primary_port_uuid != ""
      error_message = "fabric_origin = port requires primary_port_uuid (EQUINIX_PRIMARY_PORT_UUID in .env)."
    }
    precondition {
      condition     = !local.is_router || var.create_cloud_router || var.cloud_router_uuid != ""
      error_message = "fabric_origin = cloud_router requires create_cloud_router = true or cloud_router_uuid."
    }
    precondition {
      condition     = !local.is_token || var.primary_service_token_uuid != ""
      error_message = "fabric_origin = service_token requires primary_service_token_uuid."
    }
  }

  redundancy {
    priority = "PRIMARY"
  }

  notifications {
    type   = "ALL"
    emails = var.notification_emails
  }

  dynamic "project" {
    for_each = var.project_id != null ? [1] : []
    content {
      project_id = var.project_id
    }
  }

  dynamic "order" {
    for_each = var.purchase_order_number != null ? [1] : []
    content {
      purchase_order_number = var.purchase_order_number
    }
  }

  a_side {
    dynamic "access_point" {
      for_each = local.is_token ? [] : [1]
      content {
        type = local.is_router ? "CLOUD_ROUTER" : "COLO"

        dynamic "port" {
          for_each = local.is_port ? [1] : []
          content {
            uuid = local.legs.primary.port_uuid
          }
        }

        dynamic "link_protocol" {
          for_each = local.is_port ? [1] : []
          content {
            type     = var.port_link_protocol
            vlan_tag = var.port_link_protocol == "DOT1Q" ? local.legs.primary.vlan : null
            # QinQ port: outer S-tag per leg + inner C-tag (Equinix requires both;
            # the edge router uses the Azure peering VLAN as its C-tag).
            vlan_s_tag = var.port_link_protocol == "QINQ" ? local.legs.primary.vlan : null
            vlan_c_tag = var.port_link_protocol == "QINQ" ? var.expressroute_vlan_c_tag : null
          }
        }

        dynamic "router" {
          for_each = local.is_router ? [1] : []
          content {
            uuid = local.cloud_router_uuid
          }
        }
      }
    }

    dynamic "service_token" {
      for_each = local.is_token ? [1] : []
      content {
        uuid = local.legs.primary.token_uuid
      }
    }
  }

  z_side {
    access_point {
      type               = "SP"
      authentication_key = var.expressroute_service_key
      peering_type       = "PRIVATE"

      profile {
        type = "L2_PROFILE"
        uuid = var.azure_expressroute_profile_uuid
      }

      location {
        metro_code = var.metro_code
      }

      # The C-tag becomes the ExpressRoute private-peering VLAN ID.
      link_protocol {
        type       = "QINQ"
        vlan_c_tag = var.expressroute_vlan_c_tag
      }
    }
  }
}

resource "equinix_fabric_connection" "azure_secondary" {
  count     = var.redundant ? 1 : 0
  name      = "${local.name_base}-azure-er-sec"
  type      = local.conn_type
  bandwidth = var.bandwidth_mbps

  lifecycle {
    precondition {
      condition     = !local.is_port || var.secondary_port_uuid != ""
      error_message = "A redundant port-origin connection requires secondary_port_uuid (EQUINIX_SECONDARY_PORT_UUID in .env), or set EQUINIX_REDUNDANT=false."
    }
    precondition {
      condition     = !local.is_token || var.secondary_service_token_uuid != ""
      error_message = "A redundant service_token-origin connection requires secondary_service_token_uuid."
    }
  }

  redundancy {
    priority = "SECONDARY"
    group    = one(equinix_fabric_connection.azure_primary.redundancy).group
  }

  notifications {
    type   = "ALL"
    emails = var.notification_emails
  }

  dynamic "project" {
    for_each = var.project_id != null ? [1] : []
    content {
      project_id = var.project_id
    }
  }

  dynamic "order" {
    for_each = var.purchase_order_number != null ? [1] : []
    content {
      purchase_order_number = var.purchase_order_number
    }
  }

  a_side {
    dynamic "access_point" {
      for_each = local.is_token ? [] : [1]
      content {
        type = local.is_router ? "CLOUD_ROUTER" : "COLO"

        dynamic "port" {
          for_each = local.is_port ? [1] : []
          content {
            uuid = local.legs.secondary.port_uuid
          }
        }

        dynamic "link_protocol" {
          for_each = local.is_port ? [1] : []
          content {
            type       = var.port_link_protocol
            vlan_tag   = var.port_link_protocol == "DOT1Q" ? local.legs.secondary.vlan : null
            vlan_s_tag = var.port_link_protocol == "QINQ" ? local.legs.secondary.vlan : null
            vlan_c_tag = var.port_link_protocol == "QINQ" ? var.expressroute_vlan_c_tag : null
          }
        }

        dynamic "router" {
          for_each = local.is_router ? [1] : []
          content {
            uuid = local.cloud_router_uuid
          }
        }
      }
    }

    dynamic "service_token" {
      for_each = local.is_token ? [1] : []
      content {
        uuid = local.legs.secondary.token_uuid
      }
    }
  }

  z_side {
    access_point {
      type               = "SP"
      authentication_key = var.expressroute_service_key
      peering_type       = "PRIVATE"

      profile {
        type = "L2_PROFILE"
        uuid = var.azure_expressroute_profile_uuid
      }

      location {
        metro_code = var.metro_code
      }

      link_protocol {
        type       = "QINQ"
        vlan_c_tag = var.expressroute_vlan_c_tag
      }
    }
  }
}

# -----------------------------------------------------------------------------
# cloud_router origin: the FCR runs BGP with Microsoft's MSEEs.
# Direct (interface IP) must exist before BGP on each connection.
# -----------------------------------------------------------------------------
locals {
  router_legs = local.is_router && var.configure_azure_routing ? {
    for k, v in local.legs : k => {
      connection_uuid = k == "primary" ? equinix_fabric_connection.azure_primary.id : one(equinix_fabric_connection.azure_secondary[*].id)
      peer_prefix     = v.peer_prefix
      short           = v.short
    } if v.redundancy_ok
  } : {}
}

resource "equinix_fabric_routing_protocol" "azure_direct" {
  for_each        = local.router_legs
  connection_uuid = each.value.connection_uuid
  type            = "DIRECT"
  name            = "er-${each.value.short}-direct"

  direct_ipv4 {
    equinix_iface_ip = "${cidrhost(each.value.peer_prefix, 1)}/30"
  }
}

resource "equinix_fabric_routing_protocol" "azure_bgp" {
  for_each        = local.router_legs
  connection_uuid = each.value.connection_uuid
  type            = "BGP"
  name            = "er-${each.value.short}-bgp"
  customer_asn    = var.microsoft_asn

  bgp_ipv4 {
    customer_peer_ip = cidrhost(each.value.peer_prefix, 2)
    enabled          = true
  }

  depends_on = [equinix_fabric_routing_protocol.azure_direct]
}

# Optional FCR -> your cage router leg, so the Kubernetes node subnet is
# reachable from (and advertised to) Azure through the FCR.
resource "equinix_fabric_connection" "fcr_to_cage" {
  count     = local.is_router && var.fcr_customer_port_uuid != "" ? 1 : 0
  name      = "${local.name_base}-fcr-to-cage"
  type      = "IP_VC"
  bandwidth = var.bandwidth_mbps

  notifications {
    type   = "ALL"
    emails = var.notification_emails
  }

  dynamic "project" {
    for_each = var.project_id != null ? [1] : []
    content {
      project_id = var.project_id
    }
  }

  a_side {
    access_point {
      type = "CLOUD_ROUTER"
      router {
        uuid = local.cloud_router_uuid
      }
    }
  }

  z_side {
    access_point {
      type = "COLO"
      port {
        uuid = var.fcr_customer_port_uuid
      }
      link_protocol {
        type     = "DOT1Q"
        vlan_tag = var.fcr_customer_vlan_tag
      }
      location {
        metro_code = var.metro_code
      }
    }
  }
}

resource "equinix_fabric_routing_protocol" "cage_direct" {
  count           = length(equinix_fabric_connection.fcr_to_cage)
  connection_uuid = equinix_fabric_connection.fcr_to_cage[0].id
  type            = "DIRECT"
  name            = "cage-direct"

  direct_ipv4 {
    equinix_iface_ip = "${cidrhost(var.fcr_customer_peer_prefix, 1)}/30"
  }
}

resource "equinix_fabric_routing_protocol" "cage_bgp" {
  count           = length(equinix_fabric_connection.fcr_to_cage)
  connection_uuid = equinix_fabric_connection.fcr_to_cage[0].id
  type            = "BGP"
  name            = "cage-bgp"
  customer_asn    = var.fcr_customer_asn

  bgp_ipv4 {
    customer_peer_ip = cidrhost(var.fcr_customer_peer_prefix, 2)
    enabled          = true
  }

  depends_on = [equinix_fabric_routing_protocol.cage_direct]
}
