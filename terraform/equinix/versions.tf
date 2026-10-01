# Equinix root: Equinix Fabric virtual connection(s) from the Equinix site to
# the Azure ExpressRoute circuit created by terraform/azure, plus (optionally)
# a Fabric Cloud Router and its routing protocols.
#
# NOTE: Equinix Metal reached end of life on 2026-06-30 and provider v5
# removed all equinix_metal_* resources. The Kubernetes cluster itself runs on
# hardware in an Equinix IBX (BYO) - see equinix/ and docs/EQUINIX-CLUSTER.md.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    equinix = {
      source  = "equinix/equinix"
      version = "~> 5.2"
    }
  }

  # Local state by default. See terraform/bootstrap/README.md.
}
