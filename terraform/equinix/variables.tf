variable "name_prefix" {
  description = "Short prefix applied to Equinix object names (see .env NAME_PREFIX)."
  type        = string
  default     = "eqarc"
}

variable "environment" {
  description = "Environment marker used in names (see .env ENVIRONMENT)."
  type        = string
  default     = "demo"
}

# -----------------------------------------------------------------------------
# Hand-off from terraform/azure
# -----------------------------------------------------------------------------
variable "expressroute_service_key" {
  description = "Service key of the Azure ExpressRoute circuit. Supplied ONLY via the process-scoped TF_VAR_expressroute_service_key env var set by scripts/05-connect-expressroute.ps1 - never put it in a tfvars file."
  type        = string
  sensitive   = true
  default     = null
}

variable "bandwidth_mbps" {
  description = "Connection bandwidth in Mbps - must equal the ExpressRoute circuit bandwidth."
  type        = number
  default     = 50
}

variable "expressroute_vlan_c_tag" {
  description = "Customer VLAN (C-tag) used for ExpressRoute private peering. Must equal terraform/azure var.expressroute_vlan_id."
  type        = number
  default     = 200
}

variable "azure_expressroute_profile_uuid" {
  description = "Equinix Fabric service profile for Azure ExpressRoute (commercial cloud). Azure Government: 0de4e413-edd7-4325-912f-7c8a4428e156."
  type        = string
  default     = "a1390b22-bbe0-4e93-ad37-85beef9d254d"
}

# -----------------------------------------------------------------------------
# Order details
# -----------------------------------------------------------------------------
variable "metro_code" {
  description = "Equinix metro of the ExpressRoute peering location. SV = Silicon Valley (Equinix SV1), DC = Washington DC, CH = Chicago, SE = Seattle, DA = Dallas."
  type        = string
  default     = "SV"
}

variable "fabric_origin" {
  description = "A-side asset type: 'port' (your Fabric ports + your edge router does BGP), 'cloud_router' (Equinix Fabric Cloud Router does BGP to Microsoft) or 'service_token' (A-side token from a partner/Network Edge)."
  type        = string
  default     = "port"

  validation {
    condition     = contains(["port", "cloud_router", "service_token"], var.fabric_origin)
    error_message = "fabric_origin must be port, cloud_router or service_token."
  }
}

variable "redundant" {
  description = "Order a primary + secondary connection pair (recommended; Microsoft's SLA requires redundancy)."
  type        = bool
  default     = true
}

variable "notification_emails" {
  description = "Email addresses notified by Equinix about connection status changes."
  type        = list(string)

  validation {
    condition     = length(var.notification_emails) > 0
    error_message = "At least one notification email is required by Equinix Fabric."
  }
}

variable "project_id" {
  description = "Equinix IAM project ID to create the connections in (null = account default)."
  type        = string
  default     = null
}

variable "purchase_order_number" {
  description = "Optional purchase order number for Equinix billing."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# fabric_origin = "port"
# -----------------------------------------------------------------------------
variable "primary_port_uuid" {
  description = "UUID of the primary Fabric port in your Equinix cage."
  type        = string
  default     = ""
}

variable "secondary_port_uuid" {
  description = "UUID of the secondary Fabric port (redundant pair)."
  type        = string
  default     = ""
}

variable "port_link_protocol" {
  description = "Encapsulation of your ports: DOT1Q or QINQ."
  type        = string
  default     = "DOT1Q"

  validation {
    condition     = contains(["DOT1Q", "QINQ"], var.port_link_protocol)
    error_message = "port_link_protocol must be DOT1Q or QINQ."
  }
}

variable "primary_vlan_tag" {
  description = "VLAN your edge router uses on the primary port (the S-tag for QINQ ports)."
  type        = number
  default     = 1010
}

variable "secondary_vlan_tag" {
  description = "VLAN your edge router uses on the secondary port (the S-tag for QINQ ports)."
  type        = number
  default     = 1020
}

variable "edge_asn" {
  description = "BGP ASN of your edge router (port / service_token origin). Passed through as the Azure private peering peer ASN."
  type        = number
  default     = 65080
}

# -----------------------------------------------------------------------------
# fabric_origin = "cloud_router"
# -----------------------------------------------------------------------------
variable "create_cloud_router" {
  description = "Create a new Fabric Cloud Router (true) or use cloud_router_uuid (false)."
  type        = bool
  default     = false
}

variable "cloud_router_uuid" {
  description = "Existing Fabric Cloud Router UUID (when create_cloud_router = false)."
  type        = string
  default     = ""
}

variable "cloud_router_package" {
  description = "Fabric Cloud Router package code (STANDARD is enough for this demo)."
  type        = string
  default     = "STANDARD"
}

variable "account_number" {
  description = "Equinix billing account number (required to create a Fabric Cloud Router)."
  type        = string
  default     = null
}

variable "expressroute_primary_peer_prefix" {
  description = "Primary private-peering /30 (same as terraform/azure). The FCR takes the 1st usable IP, Microsoft the 2nd."
  type        = string
  default     = "192.168.250.0/30"
}

variable "expressroute_secondary_peer_prefix" {
  description = "Secondary private-peering /30 (same as terraform/azure)."
  type        = string
  default     = "192.168.250.4/30"
}

variable "microsoft_asn" {
  description = "Microsoft's ASN on ExpressRoute private peering."
  type        = number
  default     = 12076
}

variable "configure_azure_routing" {
  description = "cloud_router origin: create the FCR's Direct + BGP routing protocols toward Microsoft. Equinix recommends configuring Azure private peering FIRST, so scripts/05-connect-expressroute.ps1 sets this false on the first pass and true after peering exists."
  type        = bool
  default     = true
}

variable "fcr_customer_port_uuid" {
  description = "Optional: your cage port to connect the FCR to (the routed path to the Kubernetes nodes). Empty = manage that leg yourself."
  type        = string
  default     = ""
}

variable "fcr_customer_vlan_tag" {
  description = "DOT1Q VLAN on fcr_customer_port_uuid for the FCR-to-cage connection."
  type        = number
  default     = 1030
}

variable "fcr_customer_peer_prefix" {
  description = "/30 between the FCR (1st usable IP) and your cage router (2nd usable IP)."
  type        = string
  default     = "192.168.251.0/30"
}

variable "fcr_customer_asn" {
  description = "BGP ASN of your cage router on the FCR-to-cage connection."
  type        = number
  default     = 65080
}

# -----------------------------------------------------------------------------
# fabric_origin = "service_token"
# -----------------------------------------------------------------------------
variable "primary_service_token_uuid" {
  description = "A-side service token for the primary connection."
  type        = string
  default     = ""
}

variable "secondary_service_token_uuid" {
  description = "A-side service token for the secondary connection."
  type        = string
  default     = ""
}
