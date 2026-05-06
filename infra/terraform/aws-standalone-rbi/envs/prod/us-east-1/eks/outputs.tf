output "cluster_name" {
  description = "EKS cluster name for the Kubernetes apps root."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded EKS cluster certificate authority data."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_security_group_id" {
  description = "Primary EKS cluster security group ID."
  value       = module.eks.cluster_security_group_id
}

output "standard_node_group_name" {
  description = "Standard managed node group for RBI control workloads."
  value       = module.eks.standard_node_group_name
}

output "kata_node_group_name" {
  description = "Dedicated bare-metal Kata managed node group for RBI workers."
  value       = module.kata_nodegroup.node_group_name
}

output "kata_launch_template_id" {
  description = "Launch template ID used by the Kata node group."
  value       = module.kata_nodegroup.launch_template_id
}

output "kata_launch_template_latest_version" {
  description = "Latest launch template version used by the Kata node group."
  value       = module.kata_nodegroup.launch_template_latest_version
}

output "kata_capacity_type" {
  description = "Capacity type used by the Kata managed node group."
  value       = module.kata_nodegroup.capacity_type
}

output "kata_instance_types" {
  description = "Instance types used by the Kata managed node group."
  value       = module.kata_nodegroup.instance_types
}
