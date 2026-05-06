output "ecr_repository_urls" {
  description = "ECR repository URLs keyed by logical repository name."
  value       = module.ecr.repository_urls
}

output "ecr_repository_arns" {
  description = "ECR repository ARNs keyed by logical repository name."
  value       = module.ecr.repository_arns
}

output "ecr_repository_names" {
  description = "ECR repository names keyed by logical repository name."
  value       = module.ecr.repository_names
}
