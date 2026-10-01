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
  description = "Owner tag (see .env OWNER). Required so every resource is attributable."
  type        = string
}

variable "expiration_date" {
  description = "Informational teardown-by date tag (see .env EXPIRATION_DATE). Advisory only."
  type        = string
  default     = null
}

variable "region" {
  description = "AWS region. Defaults to us-west-2 (closest major region to Ignite in San Francisco). Overridden by scripts/02-select-regions.ps1."
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "Named AWS CLI/SSO profile (see .env AWS_PROFILE). Null = default credential chain."
  type        = string
  default     = null
}

variable "aws_assume_role_arn" {
  description = "Optional IAM role ARN to assume (see .env AWS_ASSUME_ROLE_ARN)."
  type        = string
  default     = null
}

variable "expected_account_id" {
  description = "Optional safety check: refuse to apply unless credentials resolve to this 12-digit account."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "CIDR block for the demo VPC (must not overlap the Azure hub 10.50.0.0/16 or the Equinix site)."
  type        = string
  default     = "10.60.0.0/16"
}

variable "cluster_version" {
  description = "EKS Kubernetes version (standard support through Ignite 2026; validated for Arc in the July 2026 fleet-manager-arc-demo run)."
  type        = string
  default     = "1.35"
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group (t3.large = 2 vCPU / 8 GiB)."
  type        = string
  default     = "t3.large"
}

variable "node_desired_size" {
  description = "Desired node count for the managed node group."
  type        = number
  default     = 2

  validation {
    condition     = var.node_desired_size >= 1 && var.node_desired_size <= 10
    error_message = "node_desired_size must be between 1 and 10 for this demo."
  }
}

variable "node_min_size" {
  description = "Minimum node count."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 3
}

variable "node_capacity_type" {
  description = "ON_DEMAND (recommended for a live demo) or SPOT (cheaper, may be interrupted)."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "enable_aws_load_balancer_controller" {
  description = "Install the AWS Load Balancer Controller (Helm + IRSA) so the frontend gets a modern NLB."
  type        = bool
  default     = true
}
