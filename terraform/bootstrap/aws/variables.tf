variable "create_state_backend" {
  description = "If true, creates an S3 bucket (versioned, encrypted, public access blocked) for terraform/aws remote state. Default false."
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
  description = "Required when create_state_backend = true: globally unique suffix (1-20 lowercase alphanumeric/hyphen), e.g. part of your account ID."
  type        = string
  default     = ""

  validation {
    condition     = var.state_storage_suffix == "" || can(regex("^[a-z0-9-]{1,20}$", var.state_storage_suffix))
    error_message = "state_storage_suffix must be empty, or 1-20 lowercase alphanumeric/hyphen characters."
  }
}

variable "aws_region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "Named AWS CLI/SSO profile. Null = default credential chain."
  type        = string
  default     = null
}
