locals {
  backend_snippet = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${var.create_state_backend ? aws_s3_bucket.state[0].bucket : ""}"
        key          = "aws.tfstate"
        region       = "${var.aws_region}"
        use_lockfile = true
      }
    }
  EOT
}

output "state_backend_config" {
  description = "Ready-to-paste s3 backend block for terraform/aws/versions.tf."
  value       = var.create_state_backend ? local.backend_snippet : "create_state_backend is false - no backend created. This demo uses local state; see ../README.md."
}
