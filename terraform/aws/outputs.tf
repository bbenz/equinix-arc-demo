output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.demo.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.demo.endpoint
}

output "region" {
  description = "AWS region used by this root."
  value       = var.region
}

output "account_id" {
  description = "AWS account ID resolved from the active credentials."
  value       = data.aws_caller_identity.current.account_id
}

output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.demo.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs. scripts/08-deploy-workload.ps1 renders them into the AWS rule of kubernetes/overrides/frontend-service-override.yaml."
  value       = aws_subnet.public[*].id
}

output "kubeconfig_command" {
  description = "Fetches the EKS kubeconfig into the repo-wide 'eks-demo' context (run by scripts/04-apply.ps1). With aws_assume_role_arn, kubectl assumes the same role that created the cluster (the only principal with an EKS access entry)."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.demo.name} --region ${var.region} --alias eks-demo${var.aws_profile != null ? " --profile ${var.aws_profile}" : ""}${var.aws_assume_role_arn != null ? " --role-arn ${var.aws_assume_role_arn}" : ""}"
}
