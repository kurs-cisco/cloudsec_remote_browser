output "deploy_role_name" {
  description = "RBI deploy role name."
  value       = local.deploy_role_name
}

output "deploy_role_arn" {
  description = "RBI deploy role ARN, created or expected."
  value       = local.deploy_role_arn
}

output "security_admin_role_name" {
  description = "RBI security administrator role name."
  value       = local.security_admin_role_name
}

output "security_admin_role_arn" {
  description = "RBI security administrator role ARN, created or expected."
  value       = local.security_admin_role_arn
}

output "swg_read_role_name" {
  description = "SWG RBI secret-read role name."
  value       = local.swg_read_role_name
}

output "swg_read_role_arn" {
  description = "SWG RBI secret-read role ARN, created, validated, or externally supplied."
  value       = local.swg_read_role_arn
}

output "swg_resource_access_role_name" {
  description = "SWG RBI resource-access role name."
  value       = local.swg_resource_access_role_name
}

output "swg_resource_access_role_arn" {
  description = "SWG RBI resource-access role ARN, created, validated, or externally supplied."
  value       = local.swg_resource_access_role_arn
}

output "data_root_kms_admin_principal_arns" {
  description = "Principal ARNs to pass to the data root kms_admin_principal_arns variable."
  value       = local.data_root_kms_admin_principal_arns
}

output "data_root_swg_read_role_arns" {
  description = "Principal ARNs to pass to the data root swg_read_role_arns variable."
  value       = local.data_root_swg_read_role_arns
}

output "secret_read_resources" {
  description = "Secrets Manager ARN resources covered by generated read policies."
  value       = local.secret_read_resources
}

output "kms_decrypt_resources" {
  description = "KMS resources covered by generated decrypt policies. Empty means no identity-side KMS decrypt policy was attached."
  value       = local.kms_decrypt_resources
}

output "secret_read_policy_json" {
  description = "Generated non-secret Secrets Manager/KMS read policy JSON for external SWG roles."
  value       = local.has_secret_read_policy ? data.aws_iam_policy_document.secret_read[0].json : null
}

output "security_admin_policy_json" {
  description = "Generated non-secret security-admin policy JSON."
  value       = local.has_security_admin_policy ? data.aws_iam_policy_document.security_admin[0].json : null
}

output "deploy_state_policy_json" {
  description = "Generated non-secret Terraform state backend policy JSON."
  value       = local.has_deploy_state_policy ? data.aws_iam_policy_document.deploy_state[0].json : null
}

output "bootstrap_role_summary" {
  description = "Non-secret summary of bootstrap IAM role wiring."
  value = {
    deploy_role_arn              = local.deploy_role_arn
    security_admin_role_arn      = local.security_admin_role_arn
    swg_read_role_arn            = local.swg_read_role_arn
    swg_resource_access_role_arn = local.swg_resource_access_role_arn
    rbi_account_id               = local.rbi_account_id
    swg_account_id               = local.swg_account_id
    same_account                 = local.rbi_account_id == local.swg_account_id
    kms_key_arns_supplied        = length(var.kms_key_arns) > 0
    secret_resources_supplied    = length(local.secret_read_resources) > 0
  }
}
