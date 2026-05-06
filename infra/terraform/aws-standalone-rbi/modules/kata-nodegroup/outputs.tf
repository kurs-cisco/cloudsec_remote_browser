output "node_group_name" {
  description = "Kata managed node group name."
  value       = aws_eks_node_group.kata.node_group_name
}

output "node_group_arn" {
  description = "Kata managed node group ARN."
  value       = aws_eks_node_group.kata.arn
}

output "node_role_arn" {
  description = "IAM role ARN used by the Kata managed node group."
  value       = local.node_role_arn
}

output "launch_template_id" {
  description = "Kata launch template ID."
  value       = aws_launch_template.kata.id
}

output "launch_template_latest_version" {
  description = "Latest Kata launch template version."
  value       = aws_launch_template.kata.latest_version
}

output "node_labels" {
  description = "Kata worker node labels."
  value       = var.node_labels
}

output "node_taints" {
  description = "Kata worker node taints."
  value       = var.node_taints
}

output "capacity_type" {
  description = "Capacity type used by the Kata managed node group."
  value       = var.capacity_type
}

output "instance_types" {
  description = "Instance types used by the Kata managed node group."
  value       = local.instance_types
}

output "rendered_user_data" {
  description = "Rendered AL2023 nodeadm MIME user data for inspection."
  value       = local.user_data
}
