locals {
  backend_snippet = <<-EOT
    # terraform/azure/versions.tf (key = "azure.tfstate") and
    # terraform/equinix/versions.tf (key = "equinix.tfstate")
    terraform {
      backend "azurerm" {
        resource_group_name  = "${var.create_state_backend ? azurerm_resource_group.state[0].name : ""}"
        storage_account_name = "${var.create_state_backend ? azurerm_storage_account.state[0].name : ""}"
        container_name       = "${var.create_state_backend ? azurerm_storage_container.state[0].name : ""}"
        key                  = "azure.tfstate"
      }
    }
  EOT
}

output "state_backend_config" {
  description = "Ready-to-paste azurerm backend block (change key to equinix.tfstate for terraform/equinix)."
  value       = var.create_state_backend ? local.backend_snippet : "create_state_backend is false - no backend created. This demo uses local state; see ../README.md."
}
