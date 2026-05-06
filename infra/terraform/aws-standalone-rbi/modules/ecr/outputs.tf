output "repository_names" {
  description = "ECR repository names keyed by logical repository name."
  value = {
    for key, repo in aws_ecr_repository.this : key => repo.name
  }
}

output "repository_arns" {
  description = "ECR repository ARNs keyed by logical repository name."
  value = {
    for key, repo in aws_ecr_repository.this : key => repo.arn
  }
}

output "repository_urls" {
  description = "ECR repository URLs keyed by logical repository name."
  value = {
    for key, repo in aws_ecr_repository.this : key => repo.repository_url
  }
}
