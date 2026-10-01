# AWS root: VPC (2 public subnets, no NAT gateway - see main.tf), EKS cluster
# + managed node group, EKS access entries (API auth mode), and the AWS Load
# Balancer Controller for an NLB in front of the Online Boutique frontend.
#
# EKS reaches Azure Arc over the public internet (the classic multicloud
# path). Arc-connecting it and joining it to Fleet happen afterwards in
# scripts/06-connect-arc.ps1 and scripts/07-join-fleet.ps1.
#
# Adapted from the proven fleet-manager-arc-demo AWS root (July 2026 run).
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.54.0, < 7.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.2.0, < 4.0.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.2.0, < 4.0.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0, < 5.0.0"
    }
  }

  # Local state by default. See terraform/bootstrap/README.md.
  # backend "s3" {}
}
