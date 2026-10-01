# The aws provider uses the default AWS credential chain (env vars, SSO/shared
# profile, or an assumed role) - never a static access key in this repo.
provider "aws" {
  region  = var.region
  profile = var.aws_profile

  dynamic "assume_role" {
    for_each = var.aws_assume_role_arn != null ? [1] : []
    content {
      role_arn = var.aws_assume_role_arn
    }
  }

  default_tags {
    tags = {
      owner       = var.owner
      project     = var.project
      environment = var.environment
      demo        = "equinix-arc-online-boutique"
      managed_by  = "terraform"
      cloud       = "aws"
    }
  }
}

# kubernetes/helm authenticate to the EKS cluster created by this root with a
# short-lived STS token. On a very first apply from empty state, re-run once
# if you hit "provider configuration cannot be determined".
provider "kubernetes" {
  host                   = aws_eks_cluster.demo.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.demo.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.demo.token
}

provider "helm" {
  kubernetes = {
    host                   = aws_eks_cluster.demo.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.demo.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.demo.token
  }
}
