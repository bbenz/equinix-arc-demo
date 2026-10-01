# =============================================================================
# Naming / tagging
# =============================================================================
variable "name_prefix" {
  description = "Short prefix applied to every resource name (see .env NAME_PREFIX)."
  type        = string
  default     = "eqarc"

  validation {
    condition     = can(regex("^[a-z0-9]{2,10}$", var.name_prefix))
    error_message = "name_prefix must be 2-10 lowercase alphanumeric characters."
  }
}

variable "environment" {
  description = "Environment/lifecycle tag applied to every resource (see .env ENVIRONMENT)."
  type        = string
  default     = "demo"
}

variable "project" {
  description = "Project name used only for tagging (see .env PROJECT)."
  type        = string
  default     = "equinix-arc-demo"
}

variable "owner" {
  description = "Owner tag - who to contact about this deployment (see .env OWNER). Required so every resource is attributable."
  type        = string
}

variable "expiration_date" {
  description = "Informational teardown-by date tag, e.g. 2026-11-21 (see .env EXPIRATION_DATE). Advisory only."
  type        = string
  default     = null
}

# =============================================================================
# Subscription safety + region
# =============================================================================
variable "location" {
  description = "Azure region for the hub VNet, ExpressRoute gateway, AKS, Fleet and Arc resources. Overridden by scripts/02-select-regions.ps1."
  type        = string
  default     = "westus2"
}

variable "expected_tenant_id" {
  description = "Optional safety check: refuse to apply unless the active az CLI tenant matches."
  type        = string
  default     = null
}

variable "expected_subscription_id" {
  description = "Optional safety check: refuse to apply unless the active az CLI subscription matches."
  type        = string
  default     = null
}

# =============================================================================
# AKS + Fleet Manager hub
# =============================================================================
variable "aks_node_vm_size" {
  description = "VM size for the AKS system node pool. 2x Standard_D2s_v5 runs all Online Boutique services + Redis."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "aks_node_count" {
  description = "Node count for the AKS system node pool (initial count when autoscaling is enabled)."
  type        = number
  default     = 2

  validation {
    condition     = var.aks_node_count >= 1 && var.aks_node_count <= 10
    error_message = "aks_node_count must be between 1 and 10 for this demo."
  }
}

variable "aks_autoscaling_enabled" {
  description = "Enable the cluster autoscaler on the AKS system node pool."
  type        = bool
  default     = false
}

variable "aks_min_count" {
  description = "Minimum node count when aks_autoscaling_enabled = true."
  type        = number
  default     = 1
}

variable "aks_max_count" {
  description = "Maximum node count when aks_autoscaling_enabled = true."
  type        = number
  default     = 3
}

variable "aks_sku_tier" {
  description = "AKS control plane tier. Free avoids the Uptime SLA charge - fine for a demo, not for production."
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.aks_sku_tier)
    error_message = "aks_sku_tier must be one of: Free, Standard, Premium."
  }
}

variable "fleet_hub_vm_size" {
  description = "VM size for the Fleet Manager hub cluster's single node."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "enable_diagnostics" {
  description = "Create a Log Analytics workspace + AKS diagnostics/Container Insights (extra cost; off by default)."
  type        = bool
  default     = false
}

# =============================================================================
# ExpressRoute (Equinix as connectivity provider)
# =============================================================================
variable "enable_expressroute" {
  description = <<-EOT
    Create the hub VNet, ExpressRoute circuit (provider: Equinix), ExpressRoute
    gateway and the egress proxy used by the Equinix-hosted cluster. Set false
    for "rehearsal mode" (Equinix-labeled cluster joins over the public
    internet). NOTE: ExpressRoute circuit billing starts as soon as the circuit
    (service key) is created - see docs/NETWORKING-EXPRESSROUTE.md.
  EOT
  type        = bool
  default     = true
}

variable "hub_vnet_cidr" {
  description = "Address space of the hub VNet that the ExpressRoute gateway advertises to Equinix. Must not overlap Equinix or AWS ranges."
  type        = string
  default     = "10.50.0.0/16"
}

variable "gateway_subnet_cidr" {
  description = "GatewaySubnet for the ExpressRoute gateway (/27 or larger; no NSG/UDR allowed)."
  type        = string
  default     = "10.50.0.0/27"
}

variable "proxy_subnet_cidr" {
  description = "Subnet for the egress proxy VM (Squid explicit proxy + optional storefront reverse proxy)."
  type        = string
  default     = "10.50.1.0/24"
}

variable "dns_inbound_subnet_cidr" {
  description = "Subnet (/28 minimum) delegated to the optional Azure DNS Private Resolver inbound endpoint."
  type        = string
  default     = "10.50.2.0/28"
}

variable "private_endpoint_subnet_cidr" {
  description = "Subnet for optional private endpoints (private ACR)."
  type        = string
  default     = "10.50.3.0/24"
}

variable "expressroute_peering_location" {
  description = "ExpressRoute peering location served by Equinix. 'Silicon Valley' = Equinix SV1 (closest to Moscone/Ignite). Must match the Equinix metro used in terraform/equinix."
  type        = string
  default     = "Silicon Valley"
}

variable "expressroute_bandwidth_mbps" {
  description = "Circuit bandwidth. 50 Mbps Standard/MeteredData is the cheapest SKU (~$55/month + egress) and plenty for Arc + demo traffic."
  type        = number
  default     = 50
}

variable "expressroute_sku_tier" {
  description = "Circuit tier: Standard (same geopolitical region) or Premium (global reach of VNets)."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Local", "Standard", "Premium"], var.expressroute_sku_tier)
    error_message = "expressroute_sku_tier must be Local, Standard or Premium."
  }
}

variable "expressroute_sku_family" {
  description = "MeteredData (pay per egress GB - cheapest for a demo) or UnlimitedData."
  type        = string
  default     = "MeteredData"

  validation {
    condition     = contains(["MeteredData", "UnlimitedData"], var.expressroute_sku_family)
    error_message = "expressroute_sku_family must be MeteredData or UnlimitedData."
  }
}

variable "expressroute_gateway_sku" {
  description = "ExpressRoute virtual network gateway SKU. ErGwScale with 1 scale unit (~$0.21/hr) is the cheapest zone-redundant option; ErGw1AZ (~$0.36/hr) is the fallback."
  type        = string
  default     = "ErGwScale"

  validation {
    condition     = contains(["ErGwScale", "ErGw1AZ", "ErGw2AZ", "ErGw3AZ", "Standard", "HighPerformance", "UltraPerformance"], var.expressroute_gateway_sku)
    error_message = "Unsupported ExpressRoute gateway SKU."
  }
}

variable "expressroute_gateway_scale_units" {
  description = "Minimum and maximum scale units when expressroute_gateway_sku = ErGwScale (1 unit = 1 Gbps)."
  type        = number
  default     = 1
}

variable "expressroute_private_peering_enabled" {
  description = <<-EOT
    Create Azure private peering + the gateway-to-circuit connection. Must stay
    false until Equinix has provisioned the circuit
    (serviceProviderProvisioningState = Provisioned). scripts/lib/common.ps1
    sets this automatically from the live circuit state, so re-running
    scripts/03-init-plan.ps1 never tears the peering down.
  EOT
  type        = bool
  default     = false
}

variable "expressroute_peer_asn" {
  description = "BGP ASN of the Equinix side: your edge router's ASN (port/service-token origin) or the Fabric Cloud Router's Equinix ASN (cloud_router origin)."
  type        = number
  default     = 65080
}

variable "expressroute_primary_peer_prefix" {
  description = "Primary /30 for private peering. Your router (or the FCR) uses the 1st usable IP, Microsoft the 2nd."
  type        = string
  default     = "192.168.250.0/30"
}

variable "expressroute_secondary_peer_prefix" {
  description = "Secondary /30 for private peering."
  type        = string
  default     = "192.168.250.4/30"
}

variable "expressroute_vlan_id" {
  description = "Private peering VLAN ID. Must equal the C-tag configured on the Equinix Fabric connection (terraform/equinix var.expressroute_vlan_c_tag)."
  type        = number
  default     = 200
}

# =============================================================================
# Equinix site + egress proxy
# =============================================================================
variable "equinix_onprem_prefixes" {
  description = "Prefixes advertised from the Equinix site over ExpressRoute (Kubernetes node subnet at minimum). Only these sources may use the egress proxy."
  type        = list(string)
  default     = ["10.80.0.0/24"]

  validation {
    condition     = length(var.equinix_onprem_prefixes) > 0 && alltrue([for p in var.equinix_onprem_prefixes : can(cidrhost(p, 0))])
    error_message = "equinix_onprem_prefixes must contain at least one valid CIDR."
  }
}

variable "proxy_vm_size" {
  description = "VM size for the egress proxy (Squid + nginx)."
  type        = string
  default     = "Standard_B2s"
}

variable "proxy_port" {
  description = "TCP port of the explicit (passthrough, non-TLS-terminating) Squid proxy."
  type        = number
  default     = 3128
}

variable "proxy_allow_workload_registries" {
  description = "Allow the Equinix cluster to pull the demo's public images (Online Boutique on Artifact Registry, Redis/busybox/K3s system images on Docker Hub) through the proxy."
  type        = bool
  default     = true
}

variable "proxy_allow_k3s_bootstrap" {
  description = "Allow the K3s installer/binary download hosts (get.k3s.io, update.k3s.io, github.com) through the proxy."
  type        = bool
  default     = true
}

variable "proxy_extra_allowed_domains" {
  description = "Additional Squid dstdomain entries (leading dot = include subdomains), e.g. Container Insights endpoints."
  type        = list(string)
  default     = []
}

variable "storefront_allowed_cidrs" {
  description = "Public CIDRs (e.g. the presenter's IP/32) allowed to reach the Equinix storefront published by the proxy VM's nginx. Empty = not published."
  type        = list(string)
  default     = []
}

variable "equinix_storefront_upstreams" {
  description = "ip:port targets of the Equinix cluster's frontend-external LoadBalancer (K3s ServiceLB = node IPs:80). Empty = nginx returns a placeholder page."
  type        = list(string)
  default     = []
}

# =============================================================================
# Optional "Private Link" extras (from the original Equinix demo plan)
# =============================================================================
variable "enable_private_acr" {
  description = "Create a Premium ACR reachable only through a private endpoint in the hub VNet (anonymous pull). Equinix nodes reach it through the proxy over ExpressRoute."
  type        = bool
  default     = false
}

variable "enable_dns_private_resolver" {
  description = "Create an Azure DNS Private Resolver inbound endpoint so the Equinix site's DNS can conditionally forward privatelink.* zones over ExpressRoute."
  type        = bool
  default     = false
}
