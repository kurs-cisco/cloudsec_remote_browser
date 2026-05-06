module "bootstrap_iam" {
  source = "../../modules/bootstrap-iam"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region

  role_name_prefix         = var.role_name_prefix
  rbi_account_id           = var.rbi_account_id
  swg_account_id           = var.swg_account_id
  role_path                = var.role_path
  permissions_boundary_arn = var.permissions_boundary_arn
  max_session_duration     = var.max_session_duration
  force_detach_policies    = var.force_detach_policies
  validate_existing_roles  = var.validate_existing_roles

  create_deploy_role              = var.create_deploy_role
  create_security_admin_role      = var.create_security_admin_role
  create_swg_read_role            = var.create_swg_read_role
  create_swg_resource_access_role = var.create_swg_resource_access_role

  deploy_role_name              = var.deploy_role_name
  security_admin_role_name      = var.security_admin_role_name
  swg_read_role_name            = var.swg_read_role_name
  swg_resource_access_role_name = var.swg_resource_access_role_name

  external_swg_read_role_arn            = var.external_swg_read_role_arn
  external_swg_resource_access_role_arn = var.external_swg_resource_access_role_arn

  deploy_trusted_principal_arns              = var.deploy_trusted_principal_arns
  security_admin_trusted_principal_arns      = var.security_admin_trusted_principal_arns
  swg_read_trusted_principal_arns            = var.swg_read_trusted_principal_arns
  swg_resource_access_trusted_principal_arns = var.swg_resource_access_trusted_principal_arns

  deploy_role_external_ids            = var.deploy_role_external_ids
  security_admin_external_ids         = var.security_admin_external_ids
  swg_read_external_ids               = var.swg_read_external_ids
  swg_resource_access_external_ids    = var.swg_resource_access_external_ids
  require_mfa_for_deploy_role         = var.require_mfa_for_deploy_role
  require_mfa_for_security_admin_role = var.require_mfa_for_security_admin_role

  attach_deploy_state_policy   = var.attach_deploy_state_policy
  terraform_state_bucket_arns  = local.state_bucket_arns
  terraform_state_key_prefixes = local.terraform_state_key_prefixes
  terraform_lock_table_arns    = local.state_lock_table_arns

  allow_deploy_role_to_assume_security_admin = var.allow_deploy_role_to_assume_security_admin
  deploy_assumable_role_arns                 = var.deploy_assumable_role_arns

  deploy_role_managed_policy_arns             = var.deploy_role_managed_policy_arns
  security_admin_managed_policy_arns          = var.security_admin_managed_policy_arns
  swg_read_managed_policy_arns                = var.swg_read_managed_policy_arns
  swg_resource_access_managed_policy_arns     = var.swg_resource_access_managed_policy_arns
  deploy_role_inline_policy_documents         = var.deploy_role_inline_policy_documents
  security_admin_inline_policy_documents      = var.security_admin_inline_policy_documents
  swg_read_inline_policy_documents            = var.swg_read_inline_policy_documents
  swg_resource_access_inline_policy_documents = var.swg_resource_access_inline_policy_documents

  kms_key_arns                       = var.kms_key_arns
  secret_arns                        = var.secret_arns
  secret_arn_patterns                = var.secret_arn_patterns
  enable_default_secret_arn_patterns = var.enable_default_secret_arn_patterns
  secret_name_prefix                 = var.secret_name_prefix
  default_secret_keys                = var.default_secret_keys
  allow_kms_decrypt_without_key_arns = var.allow_kms_decrypt_without_key_arns

  attach_secret_read_policy_to_swg_read_role        = var.attach_secret_read_policy_to_swg_read_role
  attach_secret_read_policy_to_resource_access_role = var.attach_secret_read_policy_to_resource_access_role
  attach_security_admin_policy                      = var.attach_security_admin_policy

  tags = var.tags
}
