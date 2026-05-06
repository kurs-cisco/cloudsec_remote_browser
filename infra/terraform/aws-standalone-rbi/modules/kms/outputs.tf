output "key_id" {
  description = "KMS key ID."
  value       = aws_kms_key.this.key_id
}

output "key_arn" {
  description = "KMS key ARN."
  value       = aws_kms_key.this.arn
}

output "alias_names" {
  description = "Created KMS alias names."
  value       = [for alias_resource in aws_kms_alias.this : alias_resource.name]
}

output "policy_json" {
  description = "Rendered KMS key policy JSON."
  value       = data.aws_iam_policy_document.this.json
}
