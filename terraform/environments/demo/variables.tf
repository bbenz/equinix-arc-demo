variable "azure_state_path" {
  description = "Path to the terraform/azure root's local state file."
  type        = string
  default     = "../../azure/terraform.tfstate"
}

variable "aws_state_path" {
  description = "Path to the terraform/aws root's local state file."
  type        = string
  default     = "../../aws/terraform.tfstate"
}

variable "equinix_state_path" {
  description = "Path to the terraform/equinix root's local state file."
  type        = string
  default     = "../../equinix/terraform.tfstate"
}
