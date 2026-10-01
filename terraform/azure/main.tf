data "azurerm_client_config" "current" {}

# Fail fast (before creating anything) if the active az CLI session isn't the
# tenant/subscription the operator expects.
check "expected_azure_identity" {
  assert {
    condition = (
      var.expected_tenant_id == null ||
      data.azurerm_client_config.current.tenant_id == var.expected_tenant_id
    )
    error_message = "Active az CLI tenant (${data.azurerm_client_config.current.tenant_id}) does not match var.expected_tenant_id. Run `az login --tenant <id>` first."
  }
  assert {
    condition = (
      var.expected_subscription_id == null ||
      data.azurerm_client_config.current.subscription_id == var.expected_subscription_id
    )
    error_message = "Active az CLI subscription (${data.azurerm_client_config.current.subscription_id}) does not match var.expected_subscription_id. Run `az account set --subscription <id>` first."
  }
}

locals {
  name_base = "${var.name_prefix}-${var.environment}"

  tags = merge(
    {
      owner       = var.owner
      project     = var.project
      environment = var.environment
      demo        = "equinix-arc-online-boutique"
      managed_by  = "terraform"
      cloud       = "azure"
    },
    var.expiration_date != null ? { expiration_date = var.expiration_date } : {}
  )

  # --- Egress proxy allowlist (Squid dstdomain syntax; leading dot = subdomains) ---
  # Arc gateway reduces the Arc-enabled Kubernetes requirement to these FQDNs:
  # https://learn.microsoft.com/azure/azure-arc/kubernetes/arc-gateway-simplify-networking
  arc_gateway_domains = [
    ".gw.arc.azure.com",         # <prefix>.gw.arc.azure.com - the Arc gateway itself
    "management.azure.com",      # ARM control channel
    ".obo.arc.azure.com",        # <region>.obo.arc.azure.com - Cluster Connect
    "login.microsoftonline.com", # Entra ID tokens
    ".login.microsoft.com",      # <region>.login.microsoft.com
    ".his.arc.azure.com",        # gbl.his.arc.azure.com + <region>.his.arc.azure.com
    "mcr.microsoft.com",         # Arc agent + Fleet extension images
    ".data.mcr.microsoft.com",
  ]

  # Fleet member agents talk to the Fleet hub cluster's API server, which is
  # not in the Arc gateway endpoint list (verified 2026-09-30).
  fleet_domains = [".azmk8s.io"]

  # Images used by kubernetes/base and K3s system components. Artifact Registry
  # serves blobs from the same host (verified 2026-09-30); Docker Hub redirects
  # blobs to its Cloudflare CDN host.
  workload_registry_domains = var.proxy_allow_workload_registries ? [
    "us-central1-docker.pkg.dev",
    "registry-1.docker.io",
    "auth.docker.io",
    "production.cloudflare.docker.com",
  ] : []

  k3s_bootstrap_domains = var.proxy_allow_k3s_bootstrap ? [
    "get.k3s.io",
    "update.k3s.io",
    "github.com",
    ".githubusercontent.com",
  ] : []

  private_acr_domains = var.enable_private_acr ? [".azurecr.io"] : []

  proxy_allowed_domains = distinct(concat(
    local.arc_gateway_domains,
    local.fleet_domains,
    local.workload_registry_domains,
    local.k3s_bootstrap_domains,
    local.private_acr_domains,
    var.proxy_extra_allowed_domains,
  ))
}

resource "azurerm_resource_group" "demo" {
  name     = "${local.name_base}-rg"
  location = var.location
  tags     = local.tags
}

# --- Resource provider registration: deliberately NOT Terraform-managed ---
# azurerm 5.x registers nothing by default, which is what we want: on a shared
# subscription a Terraform-managed registration could be torn down by
# `terraform destroy`. scripts/01-test-cloud-access.ps1 -RegisterProviders
# registers Microsoft.ContainerService, Microsoft.Network, Microsoft.Compute,
# Microsoft.Kubernetes, Microsoft.KubernetesConfiguration,
# Microsoft.ExtendedLocation, Microsoft.HybridCompute (Arc gateway) and,
# when needed, Microsoft.ContainerRegistry / Microsoft.OperationalInsights.
