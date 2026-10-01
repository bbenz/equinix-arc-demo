variable "create_state_backend" {
  description = "If true, creates an Azure Storage Account + container for azurerm remote state (used by terraform/azure and terraform/equinix). Default false."
  type        = bool
  default     = false
}

variable "name_prefix" {
  description = "Short prefix applied to every resource name (see .env NAME_PREFIX)."
  type        = string
  default     = "eqarc"
}

variable "environment" {
  description = "Environment/lifecycle tag (see .env ENVIRONMENT)."
  type        = string
  default     = "demo"
}

variable "state_storage_suffix" {
  description = "Required when create_state_backend = true: globally unique, 1-12 lowercase alphanumeric characters (storage account names cap at 24)."
  type        = string
  default     = ""

  validation {
    condition     = var.state_storage_suffix == "" || can(regex("^[a-z0-9]{1,12}$", var.state_storage_suffix))
    error_message = "state_storage_suffix must be empty, or 1-12 lowercase alphanumeric characters."
  }
}

variable "azure_subscription_id" {
  description = "Subscription for the state storage account. Null = active `az login` subscription."
  type        = string
  default     = null
}

variable "azure_location" {
  description = "Azure region for the state storage account."
  type        = string
  default     = "westus2"
}
