output "kms_key_arn" {
  description = "RBI Secrets Manager KMS key ARN."
  value       = module.kms.key_arn
}

output "secret_metadata" {
  description = "RBI-owned Secrets Manager metadata. No secret values are exposed."
  value       = module.secrets.secret_metadata
}

output "secret_arns" {
  description = "RBI-owned Secrets Manager ARNs by logical key. No secret values are exposed."
  value       = module.secrets.secret_arns
}

output "secret_names" {
  description = "RBI-owned Secrets Manager names by logical key. No secret values are exposed."
  value       = module.secrets.secret_names
}

output "swg_shared_secret_arn" {
  description = "Secrets Manager ARN for the SWG-to-RBI bootstrap/handoff shared secret placeholder."
  value       = try(module.secrets.secret_arns["swg_handoff_shared_secret"], null)
}

output "swg_shared_secret_name" {
  description = "Secrets Manager name for the SWG-to-RBI bootstrap/handoff shared secret placeholder."
  value       = try(module.secrets.secret_names["swg_handoff_shared_secret"], null)
}

output "mtls_trust_bundle_secret_arn" {
  description = "Secrets Manager ARN for the mTLS client bootstrap placeholder. Trust bundle metadata is exposed separately."
  value       = try(module.secrets.secret_arns["mtls_client_bootstrap"], null)
}

output "secret_resource_policy_read_principals" {
  description = "Cross-account SWG read principals configured in secret resource policies."
  value       = var.swg_read_role_arns
}

output "rotation_role_arns" {
  description = "Placeholder rotation IAM role ARNs by secret key."
  value       = module.secrets.rotation_role_arns
}

output "public_certificate_arns" {
  description = "Optional public ACM certificate ARNs."
  value       = module.mtls.public_certificate_arns
}

output "public_viewer_certificate_arn" {
  description = "Public ACM certificate ARN for the browser handoff/viewer endpoint."
  value       = try(module.mtls.public_certificate_arns["public_endpoint"], "")
}

output "private_ca_arns" {
  description = "ACM Private CA ARNs for mTLS trust anchors."
  value       = module.mtls.private_ca_arns
}

output "trust_bundle_metadata" {
  description = "Non-sensitive mTLS trust bundle metadata."
  value       = module.mtls.trust_bundle_metadata
}

output "trust_bundle_parameter_names" {
  description = "SSM parameter names containing non-sensitive trust bundle metadata."
  value       = module.mtls.trust_bundle_parameter_names
}

output "observability_event_rule_arns" {
  description = "EventBridge audit rule ARNs."
  value       = module.observability.event_rule_arns
}

output "rotation_log_group_names" {
  description = "CloudWatch log groups reserved for rotation Lambda placeholders."
  value       = module.observability.log_group_names
}
