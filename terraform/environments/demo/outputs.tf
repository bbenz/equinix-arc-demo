locals {
  azure   = try(data.terraform_remote_state.azure[0].outputs, {})
  aws     = try(data.terraform_remote_state.aws[0].outputs, {})
  equinix = try(data.terraform_remote_state.equinix[0].outputs, {})
}

output "summary" {
  description = "Consolidated view of all three footprints - `terraform output -json summary`."
  value = {
    azure = {
      applied                      = try(local.azure.aks_cluster_name, null) != null
      resource_group_name          = try(local.azure.resource_group_name, null)
      location                     = try(local.azure.location, null)
      aks_cluster_name             = try(local.azure.aks_cluster_name, null)
      fleet_name                   = try(local.azure.fleet_name, null)
      fleet_id                     = try(local.azure.fleet_id, null)
      kubeconfig_command           = try(local.azure.kubeconfig_command, null)
      expressroute_enabled         = try(local.azure.expressroute_enabled, null)
      expressroute_circuit_name    = try(local.azure.expressroute_circuit_name, null)
      expressroute_peering_enabled = try(local.azure.expressroute_private_peering_enabled, null)
      egress_proxy_url             = try(local.azure.egress_proxy_url, null)
      storefront_public_url        = try(local.azure.storefront_public_url, null)
    }
    aws = {
      applied            = try(local.aws.cluster_name, null) != null
      cluster_name       = try(local.aws.cluster_name, null)
      region             = try(local.aws.region, null)
      account_id         = try(local.aws.account_id, null)
      kubeconfig_command = try(local.aws.kubeconfig_command, null)
    }
    equinix = {
      applied                = try(local.equinix.connection_uuids, null) != null
      fabric_origin          = try(local.equinix.fabric_origin, null)
      metro_code             = try(local.equinix.metro_code, null)
      connection_names       = try(local.equinix.connection_names, null)
      connection_uuids       = try(local.equinix.connection_uuids, null)
      azure_peering_peer_asn = try(local.equinix.azure_peering_peer_asn, null)
    }
  }
}
