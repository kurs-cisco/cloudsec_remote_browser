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
  description = "Secrets Manager ARN for the SWG-to-RBI bootstrap/handoff shared secret."
  value       = try(module.secrets.secret_arns["swg_handoff_shared_secret"], null)
}

output "swg_shared_secret_name" {
  description = "Secrets Manager name for the SWG-to-RBI bootstrap/handoff shared secret."
  value       = try(module.secrets.secret_names["swg_handoff_shared_secret"], null)
}

output "swg_shared_secret_version_managed_by_terraform" {
  description = "Whether the SWG-to-RBI handoff shared secret version is Terraform-managed. This data root intentionally never stores secret values in Terraform state."
  value       = false
}

output "swg_shared_secret_version_stage_order" {
  description = "Version-stage read order for SWG handoff secret consumers. AWSCURRENT is required first; AWSPREVIOUS is an optional rotation fallback."
  value       = local.swg_handoff_read_stage_order
}

output "mtls_trust_bundle_secret_arn" {
  description = "Secrets Manager ARN for the mTLS client bootstrap placeholder. Trust bundle metadata is exposed separately."
  value       = try(module.secrets.secret_arns["mtls_client_bootstrap"], null)
}

output "secret_resource_policy_read_principals" {
  description = "Broad/default SWG role ARNs configured on RBI secrets that inherit the default read policy. The optional credential reader user is intentionally excluded."
  value       = var.swg_read_role_arns
}

output "swg_handoff_secret_direct_read_principals" {
  description = "Direct read principals configured only on swg_handoff_shared_secret, including the generated credential reader user when enabled."
  value       = try(coalesce(local.rbi_secret_metadata["swg_handoff_shared_secret"].read_principal_arns, []), [])
}

output "swg_credential_secret_names" {
  description = "SWG-side credential secret names created by the data root."
  value       = module.swg_credentials.secret_names
}

output "swg_credential_secret_arns" {
  description = "SWG-side credential secret ARNs created by the data root."
  value       = module.swg_credentials.secret_arns
}

output "swg_credential_secret_kms_key_arn" {
  description = "KMS key ARN used by the SWG-side credential secret when Terraform creates the key. Null when the secret is disabled or an external key ID is supplied."
  value       = try(module.swg_credentials_kms[0].key_arn, null)
}

output "swg_credential_secret_read_principals" {
  description = "Principals allowed to read the SWG-side credential secret."
  value       = var.swg_credential_secret_read_principal_arns
}

output "swg_credential_reader_user_arn" {
  description = "Optional RBI-account IAM user ARN that can read the SWG handoff signing secret. Terraform does not create or store its access key."
  value       = try(aws_iam_user.swg_credential_reader[0].arn, null)
}

output "swg_credential_secret_version_managed_by_terraform" {
  description = "Whether the SWG-side credential secret version is Terraform-managed. This data root intentionally creates only the secret container and access policy."
  value       = false
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
