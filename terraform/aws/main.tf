data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

check "expected_aws_account" {
  assert {
    condition = (
      var.expected_account_id == null ||
      data.aws_caller_identity.current.account_id == var.expected_account_id
    )
    error_message = "Active AWS account (${data.aws_caller_identity.current.account_id}) does not match var.expected_account_id. Check AWS_PROFILE / the assumed role."
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
      cloud       = "aws"
    },
    var.expiration_date != null ? { expiration_date = var.expiration_date } : {}
  )

  # EKS requires >= 2 AZs.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# =============================================================================
# Networking
# Cost decision (unchanged from fleet-manager-arc-demo): public subnets, no NAT
# gateway (~$33-66/month saved). Nodes get public IPs; the node security group
# opens only what the workload needs. Production: private subnets + NAT/VPC
# endpoints - see docs/ARCHITECTURE.md.
# =============================================================================
resource "aws_vpc" "demo" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${local.name_base}-vpc" })
}

resource "aws_internet_gateway" "demo" {
  vpc_id = aws_vpc.demo.id
  tags   = merge(local.tags, { Name = "${local.name_base}-igw" })
}

resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.demo.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name                                           = "${local.name_base}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                       = "1"
    "kubernetes.io/cluster/${local.name_base}-eks" = "shared"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.demo.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.demo.id
  }

  tags = merge(local.tags, { Name = "${local.name_base}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "nodes" {
  name        = "${local.name_base}-nodes-sg"
  description = "EKS managed node group security group for ${local.name_base}"
  vpc_id      = aws_vpc.demo.id

  tags = merge(local.tags, { Name = "${local.name_base}-nodes-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "nodes_self" {
  security_group_id            = aws_security_group.nodes.id
  description                  = "Node to node (all protocols)"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.nodes.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_cluster" {
  security_group_id            = aws_security_group.nodes.id
  description                  = "Control plane to kubelet and webhooks"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_eks_cluster.demo.vpc_config[0].cluster_security_group_id
}

# EC2 security group descriptions must not contain '>' (lesson learned).
resource "aws_vpc_security_group_ingress_rule" "nodes_nodeport_public" {
  security_group_id = aws_security_group.nodes.id
  description       = "frontend-external NLB to node NodePort range (public subnets, no NAT)"
  ip_protocol       = "tcp"
  from_port         = 30000
  to_port           = 32767
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "nodes_all_egress" {
  security_group_id = aws_security_group.nodes.id
  description       = "Outbound for image pulls, EKS API and the Arc and Fleet agents"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# =============================================================================
# IAM - cluster and node roles
# =============================================================================
resource "aws_iam_role" "cluster" {
  name = "${local.name_base}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role" "node" {
  name = "${local.name_base}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryPullOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  role       = aws_iam_role.node.name
}

# Demo simplicity; the hardened alternative is a dedicated IRSA role for aws-node.
resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

# =============================================================================
# EKS cluster + managed node group
# =============================================================================
resource "aws_eks_cluster" "demo" {
  name     = "${local.name_base}-eks"
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Avoid silently drifting onto extended-support pricing.
  upgrade_policy {
    support_type = "STANDARD"
  }

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  tags = local.tags

  depends_on = [aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy]
}

resource "aws_eks_node_group" "demo" {
  cluster_name    = aws_eks_cluster.demo.name
  node_group_name = "${local.name_base}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id

  capacity_type  = var.node_capacity_type
  instance_types = [var.node_instance_type]
  ami_type       = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryPullOnly,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
  ]
}

data "aws_eks_cluster_auth" "demo" {
  name = aws_eks_cluster.demo.name
}

# =============================================================================
# AWS Load Balancer Controller (IRSA + Helm)
# =============================================================================
data "tls_certificate" "eks_oidc" {
  count = var.enable_aws_load_balancer_controller ? 1 : 0
  url   = aws_eks_cluster.demo.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  count           = var.enable_aws_load_balancer_controller ? 1 : 0
  url             = aws_eks_cluster.demo.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc[0].certificates[0].sha1_fingerprint]
  tags            = local.tags
}

data "aws_iam_policy_document" "lbc_trust" {
  count = var.enable_aws_load_balancer_controller ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks[0].url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks[0].url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  count              = var.enable_aws_load_balancer_controller ? 1 : 0
  name               = "${local.name_base}-lbc-role"
  assume_role_policy = data.aws_iam_policy_document.lbc_trust[0].json
  tags               = local.tags
}

# Pinned local copy of the upstream policy (v3.4.1) for reproducible plans.
resource "aws_iam_policy" "lbc" {
  count       = var.enable_aws_load_balancer_controller ? 1 : 0
  name        = "${local.name_base}-lbc-policy"
  description = "AWS Load Balancer Controller IAM policy (pinned to upstream v3.4.1)"
  policy      = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  count      = var.enable_aws_load_balancer_controller ? 1 : 0
  policy_arn = aws_iam_policy.lbc[0].arn
  role       = aws_iam_role.lbc[0].name
}

resource "kubernetes_service_account_v1" "lbc" {
  count = var.enable_aws_load_balancer_controller ? 1 : 0

  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.lbc[0].arn
    }
  }

  depends_on = [aws_eks_node_group.demo]
}

resource "helm_release" "aws_lbc" {
  count      = var.enable_aws_load_balancer_controller ? 1 : 0
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.4.1"
  namespace  = "kube-system"

  set = [
    { name = "clusterName", value = aws_eks_cluster.demo.name },
    { name = "serviceAccount.create", value = "false" },
    { name = "serviceAccount.name", value = "aws-load-balancer-controller" },
    { name = "region", value = var.region },
    { name = "vpcId", value = aws_vpc.demo.id },
  ]

  depends_on = [kubernetes_service_account_v1.lbc]
}
