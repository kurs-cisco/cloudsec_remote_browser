output "deploy_role_name" {
  description = "RBI deploy role name."
  value       = module.bootstrap_iam.deploy_role_name
}

output "deploy_role_arn" {
  description = "RBI deploy role ARN."
  value       = module.bootstrap_iam.deploy_role_arn
}

output "security_admin_role_name" {
  description = "RBI security administrator role name."
  value       = module.bootstrap_iam.security_admin_role_name
}

output "security_admin_role_arn" {
  description = "RBI security administrator role ARN."
  value       = module.bootstrap_iam.security_admin_role_arn
}

output "swg_read_role_name" {
  description = "SWG RBI secret-read role name."
  value       = module.bootstrap_iam.swg_read_role_name
}

output "swg_read_role_arn" {
  description = "SWG RBI secret-read role ARN."
  value       = module.bootstrap_iam.swg_read_role_arn
}

output "swg_resource_access_role_name" {
  description = "SWG RBI resource-access role name."
  value       = module.bootstrap_iam.swg_resource_access_role_name
}

output "swg_resource_access_role_arn" {
  description = "SWG RBI resource-access role ARN."
  value       = module.bootstrap_iam.swg_resource_access_role_arn
}

output "data_root_kms_admin_principal_arns" {
  description = "Principal ARNs to pass to the data root kms_admin_principal_arns variable."
  value       = module.bootstrap_iam.data_root_kms_admin_principal_arns
}

output "data_root_swg_read_role_arns" {
  description = "Principal ARNs to pass to the data root swg_read_role_arns variable."
  value       = module.bootstrap_iam.data_root_swg_read_role_arns
}

output "secret_read_resources" {
  description = "Secrets Manager ARN resources covered by generated read policies."
  value       = module.bootstrap_iam.secret_read_resources
}

output "kms_decrypt_resources" {
  description = "KMS resources covered by generated decrypt policies."
  value       = module.bootstrap_iam.kms_decrypt_resources
}

output "secret_read_policy_json" {
  description = "Generated non-secret Secrets Manager/KMS read policy JSON for external SWG roles."
  value       = module.bootstrap_iam.secret_read_policy_json
}

output "security_admin_policy_json" {
  description = "Generated non-secret security-admin policy JSON."
  value       = module.bootstrap_iam.security_admin_policy_json
}

output "deploy_state_policy_json" {
  description = "Generated non-secret Terraform state backend policy JSON."
  value       = module.bootstrap_iam.deploy_state_policy_json
}

output "bootstrap_role_summary" {
  description = "Non-secret summary of bootstrap IAM role wiring."
  value       = module.bootstrap_iam.bootstrap_role_summary
}
