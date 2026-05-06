output "public_certificate_arns" {
  description = "Public ACM certificate ARNs by key."
  value       = { for certificate_key, certificate in aws_acm_certificate.public : certificate_key => certificate.arn }
}

output "public_certificate_validation_records" {
  description = "DNS validation records by certificate/domain key."
  value       = local.validation_records
}

output "private_ca_arns" {
  description = "ACM Private CA ARNs by key."
  value       = { for ca_key, ca in aws_acmpca_certificate_authority.private : ca_key => ca.arn }
}

output "trust_bundle_metadata" {
  description = "Non-sensitive trust bundle metadata by key."
  value       = local.trust_bundle_metadata
}

output "trust_bundle_parameter_names" {
  description = "SSM parameter names storing non-sensitive trust bundle metadata."
  value       = { for bundle_key, parameter in aws_ssm_parameter.trust_bundle_metadata : bundle_key => parameter.name }
}
