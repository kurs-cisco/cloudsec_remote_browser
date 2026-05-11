output "secret_arns" {
  description = "Secrets Manager secret ARNs by key."
  value       = { for secret_key, secret in aws_secretsmanager_secret.this : secret_key => secret.arn }
}

output "secret_names" {
  description = "Secrets Manager secret names by key."
  value       = { for secret_key, secret in aws_secretsmanager_secret.this : secret_key => secret.name }
}

output "secret_metadata" {
  description = "Non-sensitive RBI secret metadata by key."
  value = {
    for secret_key, secret in aws_secretsmanager_secret.this :
    secret_key => {
      arn          = secret.arn
      name         = secret.name
      kms_key_id   = secret.kms_key_id
      value_source = try(secret.tags["SecretMaterialManagedBy"], "out-of-band")
    }
  }
}

output "rotation_role_arns" {
  description = "Placeholder rotation IAM role ARNs by rotation key."
  value       = { for rotation_key, role in aws_iam_role.rotation : rotation_key => role.arn }
}

output "rotation_placeholders" {
  description = "Rotation placeholder metadata; no secret material is included."
  value = {
    for rotation_key, placeholder in var.rotation_placeholders :
    rotation_key => {
      secret_key          = placeholder.secret_key
      secret_arn          = aws_secretsmanager_secret.this[placeholder.secret_key].arn
      role_arn            = try(aws_iam_role.rotation[rotation_key].arn, null)
      rotation_configured = placeholder.rotation_lambda_arn != null && placeholder.rotation_lambda_arn != ""
    }
  }
}
