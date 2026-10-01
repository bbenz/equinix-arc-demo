# Both providers use the active `az login` session (Azure CLI auth) - no
# client secret, certificate, or service principal is configured here.
# azurerm 4+ needs an explicit subscription even with Azure CLI auth: the repo
# scripts pass the CLI's active subscription as ARM_SUBSCRIPTION_ID for each
# plan/apply/destroy. Running terraform by hand? First:
#   $env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
# See docs/AUTHENTICATION-AND-PERMISSIONS.md.
provider "azurerm" {
  # azurerm 5.x registers NO resource providers by default. That is the
  # behavior we want on shared subscriptions: scripts/01-test-cloud-access.ps1
  # reports (and with -RegisterProviders, registers) exactly the RPs this demo
  # needs, so a `terraform destroy` can never unregister anything.
  features {}
}

provider "azapi" {}
