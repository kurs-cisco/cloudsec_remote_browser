output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "EKS API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded EKS cluster certificate authority data."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "service_ipv4_cidr" {
  description = "Kubernetes service IPv4 CIDR assigned to the cluster."
  value       = try(aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr, null)
}

output "cluster_security_group_id" {
  description = "Primary EKS cluster security group ID."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "cluster_oidc_issuer_url" {
  description = "EKS OIDC issuer URL."
  value       = try(aws_eks_cluster.this.identity[0].oidc[0].issuer, null)
}

output "standard_node_group_name" {
  description = "Standard managed node group name."
  value       = aws_eks_node_group.standard.node_group_name
}

output "standard_node_role_arn" {
  description = "IAM role ARN used by the standard managed node group."
  value       = aws_iam_role.standard_nodes.arn
}
