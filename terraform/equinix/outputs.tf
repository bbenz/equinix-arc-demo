output "fabric_origin" {
  description = "A-side asset type used for the ExpressRoute connections."
  value       = var.fabric_origin
}

output "metro_code" {
  description = "Equinix metro of the connections."
  value       = var.metro_code
}

output "connection_uuids" {
  description = "Equinix Fabric connection UUIDs (primary, secondary)."
  value = compact([
    equinix_fabric_connection.azure_primary.id,
    one(equinix_fabric_connection.azure_secondary[*].id),
  ])
}

output "connection_names" {
  description = "Equinix Fabric connection names."
  value = compact([
    equinix_fabric_connection.azure_primary.name,
    one(equinix_fabric_connection.azure_secondary[*].name),
  ])
}

output "cloud_router_uuid" {
  description = "Fabric Cloud Router UUID (cloud_router origin only)."
  value       = local.cloud_router_uuid
}

output "azure_peering_peer_asn" {
  description = "ASN to configure as the peer ASN on Azure private peering: the FCR's Equinix ASN (cloud_router origin) or your edge router ASN."
  value       = local.is_router ? local.cloud_router_asn : var.edge_asn
}

output "expressroute_vlan_c_tag" {
  description = "Private peering VLAN ID configured on the Equinix side."
  value       = var.expressroute_vlan_c_tag
}

output "fcr_cage_leg" {
  description = "cloud_router origin with fcr_customer_port_uuid: what YOUR cage router must configure to peer with the FCR (scripts/05 renders it). null otherwise."
  value = length(equinix_fabric_connection.fcr_to_cage) > 0 ? {
    vlan_tag   = var.fcr_customer_vlan_tag
    fcr_ip     = cidrhost(var.fcr_customer_peer_prefix, 1)
    cage_ip    = cidrhost(var.fcr_customer_peer_prefix, 2)
    prefix_len = tonumber(split("/", var.fcr_customer_peer_prefix)[1])
    cage_asn   = var.fcr_customer_asn
    fcr_asn    = local.cloud_router_asn
  } : null
}

output "next_step" {
  description = "What happens next."
  value = local.is_router ? join(" ", [
    "scripts/05-connect-expressroute.ps1 enables Azure private peering (peer ASN = the FCR's Equinix ASN), then adds the FCR's Direct + BGP routing toward Microsoft.",
    length(equinix_fabric_connection.fcr_to_cage) > 0 ? "Configure your cage router's BGP session to the FCR from artifacts/edge-router-fcr-leg-frr.conf (rendered by scripts/05)." : "The cage prefixes must reach the FCR some other way (e.g. a connection you manage) - set EQUINIX_FCR_CUSTOMER_PORT_UUID to let this root build that leg.",
  ]) : "Configure BGP on your edge router from artifacts/edge-router-bgp-frr.conf or edge-router-bgp-iosxe.txt (rendered by scripts/05-connect-expressroute.ps1), then let the script finish Azure private peering."
}
