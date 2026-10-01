# Azure root: hub VNet + ExpressRoute (circuit, gateway, private peering) +
# egress proxy for the Equinix-hosted cluster, AKS, and Fleet Manager (with
# hub cluster) + AKS's own Fleet membership.
#
# Arc-connecting EKS / the Equinix cluster and joining them to Fleet is done
# imperatively by scripts/06-connect-arc.ps1 and scripts/07-join-fleet.ps1,
# because `az connectedk8s connect` must run against an already-existing
# foreign cluster (see docs/ARCHITECTURE.md).
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      # azurerm 5.x: no implicit resource-provider registration (scripts/01
      # registers the required RPs explicitly) and AKS requires an explicit
      # node_provisioning_profile block. See docs/ARCHITECTURE.md.
      source  = "hashicorp/azurerm"
      version = "~> 5.7"
    }
    azapi = {
      # Only used for the Fleet Manager *with hub cluster* - see fleet.tf.
      source  = "azure/azapi"
      version = "~> 2.13"
    }
    tls = {
      # Generates the egress proxy VM's admin SSH key (never output; no
      # inbound SSH is allowed - the VM is managed through Run Command).
      source  = "hashicorp/tls"
      version = ">= 4.0.0, < 5.0.0"
    }
  }

  # Local state by default. See terraform/bootstrap/README.md for remote state.
  # backend "azurerm" {}
}
