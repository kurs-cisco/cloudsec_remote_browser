variable "project_name" {
  description = "Project name used in tags and default secret naming."
  type        = string
  default     = "cloudsec-rbi"
}

variable "environment" {
  description = "Environment name used in default role names."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region used to build Secrets Manager ARN patterns and KMS via-service conditions."
  type        = string
}

variable "role_name_prefix" {
  description = "Short role-name prefix. Defaults to rbi so dev roles match rbi-dev-* and swg-dev-rbi-*."
  type        = string
  default     = "rbi"
}

variable "rbi_account_id" {
  description = "Account ID that owns RBI resources. Defaults to the current provider account."
  type        = string
  default     = null
}

variable "swg_account_id" {
  description = "Account ID that owns SWG-side roles. Defaults to the current provider account for same-account dev."
  type        = string
  default     = null
}

variable "role_path" {
  description = "IAM path for roles created by this module."
  type        = string
  default     = "/"
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary ARN applied to all roles created by this module."
  type        = string
  default     = null
}

variable "max_session_duration" {
  description = "Maximum role session duration in seconds."
  type        = number
  default     = 3600
}

variable "force_detach_policies" {
  description = "Whether Terraform should force-detach policies when destroying created roles."
  type        = bool
  default     = false
}

variable "validate_existing_roles" {
  description = "When a role creation flag is false and the role is in the current account, look it up with aws_iam_role to fail fast if it is missing."
  type        = bool
  default     = true
}

variable "create_deploy_role" {
  description = "Whether to create the RBI Terraform deploy role in the current provider account."
  type        = bool
  default     = true
}

variable "create_security_admin_role" {
  description = "Whether to create the RBI security administrator role in the current provider account."
  type        = bool
  default     = true
}

variable "create_swg_read_role" {
  description = "Whether to create the SWG secret-read role in the current provider account. Set false for cross-account SWG and provide an external role ARN."
  type        = bool
  default     = true
}

variable "create_swg_resource_access_role" {
  description = "Whether to create the SWG resource-access role in the current provider account. Set false for cross-account SWG and provide an external role ARN."
  type        = bool
  default     = true
}

variable "deploy_role_name" {
  description = "Optional explicit RBI deploy role name."
  type        = string
  default     = null
}

variable "security_admin_role_name" {
  description = "Optional explicit RBI security administrator role name."
  type        = string
  default     = null
}

variable "swg_read_role_name" {
  description = "Optional explicit SWG secret-read role name."
  type        = string
  default     = null
}

variable "swg_resource_access_role_name" {
  description = "Optional explicit SWG resource-access role name."
  type        = string
  default     = null
}

variable "external_swg_read_role_arn" {
  description = "Existing SWG secret-read role ARN to use when create_swg_read_role is false, especially for cross-account SWG."
  type        = string
  default     = null
}

variable "external_swg_resource_access_role_arn" {
  description = "Existing SWG resource-access role ARN to use when create_swg_resource_access_role is false, especially for cross-account SWG."
  type        = string
  default     = null
}

variable "deploy_trusted_principal_arns" {
  description = "AWS principal ARNs allowed to assume the deploy role. Defaults to the current account root."
  type        = list(string)
  default     = []
}

variable "security_admin_trusted_principal_arns" {
  description = "AWS principal ARNs allowed to assume the security-admin role. Defaults to the current account root."
  type        = list(string)
  default     = []
}

variable "swg_read_trusted_principal_arns" {
  description = "AWS principal ARNs allowed to assume the SWG read role. Defaults to the SWG account root."
  type        = list(string)
  default     = []
}

variable "swg_resource_access_trusted_principal_arns" {
  description = "AWS principal ARNs allowed to assume the SWG resource-access role. Defaults to the SWG account root."
  type        = list(string)
  default     = []
}

variable "deploy_role_external_ids" {
  description = "Optional sts:ExternalId values required to assume the deploy role."
  type        = list(string)
  default     = []
}

variable "security_admin_external_ids" {
  description = "Optional sts:ExternalId values required to assume the security-admin role."
  type        = list(string)
  default     = []
}

variable "swg_read_external_ids" {
  description = "Optional sts:ExternalId values required to assume the SWG read role."
  type        = list(string)
  default     = []
}

variable "swg_resource_access_external_ids" {
  description = "Optional sts:ExternalId values required to assume the SWG resource-access role."
  type        = list(string)
  default     = []
}

variable "require_mfa_for_deploy_role" {
  description = "Whether sts:AssumeRole into the deploy role requires MFA."
  type        = bool
  default     = false
}

variable "require_mfa_for_security_admin_role" {
  description = "Whether sts:AssumeRole into the security-admin role requires MFA."
  type        = bool
  default     = false
}

variable "attach_deploy_state_policy" {
  description = "Whether to attach a Terraform state backend policy to the deploy role when backend ARNs are supplied."
  type        = bool
  default     = true
}

variable "terraform_state_bucket_arns" {
  description = "S3 bucket ARNs for Terraform state that the deploy role may access."
  type        = list(string)
  default     = []
}

variable "terraform_state_key_prefixes" {
  description = "State object key prefixes allowed in each Terraform state bucket. Empty permits all keys in the supplied buckets."
  type        = list(string)
  default     = []
}

variable "terraform_lock_table_arns" {
  description = "DynamoDB lock table ARNs for Terraform state locking."
  type        = list(string)
  default     = []
}

variable "allow_deploy_role_to_assume_security_admin" {
  description = "Whether the deploy role gets sts:AssumeRole for the security-admin role ARN."
  type        = bool
  default     = true
}

variable "deploy_assumable_role_arns" {
  description = "Additional role ARNs the deploy role may assume."
  type        = list(string)
  default     = []
}

variable "deploy_role_managed_policy_arns" {
  description = "Additional managed policy ARNs attached to the deploy role. Keep empty unless an environment-specific deploy policy is reviewed."
  type        = list(string)
  default     = []
}

variable "security_admin_managed_policy_arns" {
  description = "Additional managed policy ARNs attached to the security-admin role."
  type        = list(string)
  default     = []
}

variable "swg_read_managed_policy_arns" {
  description = "Additional managed policy ARNs attached to the SWG read role when it is created here."
  type        = list(string)
  default     = []
}

variable "swg_resource_access_managed_policy_arns" {
  description = "Additional managed policy ARNs attached to the SWG resource-access role when it is created here."
  type        = list(string)
  default     = []
}

variable "deploy_role_inline_policy_documents" {
  description = "Additional deploy-role inline policy JSON documents keyed by policy name."
  type        = map(string)
  default     = {}
}

variable "security_admin_inline_policy_documents" {
  description = "Additional security-admin inline policy JSON documents keyed by policy name."
  type        = map(string)
  default     = {}
}

variable "swg_read_inline_policy_documents" {
  description = "Additional SWG read-role inline policy JSON documents keyed by policy name."
  type        = map(string)
  default     = {}
}

variable "swg_resource_access_inline_policy_documents" {
  description = "Additional SWG resource-access inline policy JSON documents keyed by policy name."
  type        = map(string)
  default     = {}
}

variable "kms_key_arns" {
  description = "KMS key ARNs known at bootstrap time for decrypt/admin policies. Leave empty until the data root exposes the RBI key ARN."
  type        = list(string)
  default     = []
}

variable "secret_arns" {
  description = "Exact Secrets Manager secret ARNs known at bootstrap time."
  type        = list(string)
  default     = []
}

variable "secret_arn_patterns" {
  description = "Additional Secrets Manager ARN patterns for RBI secret metadata."
  type        = list(string)
  default     = []
}

variable "enable_default_secret_arn_patterns" {
  description = "Whether to derive default RBI secret ARN patterns from secret_name_prefix and default_secret_keys."
  type        = bool
  default     = true
}

variable "secret_name_prefix" {
  description = "Secrets Manager name prefix used by the data root. Defaults to project/environment/data."
  type        = string
  default     = null
}

variable "default_secret_keys" {
  description = "Default RBI secret keys to include in derived Secrets Manager ARN patterns."
  type        = set(string)
  default = [
    "session_token_signing",
    "turn_shared_secret",
    "pool_worker_shared_secret",
    "host_agent_shared_secret",
    "swg_handoff_shared_secret",
    "mtls_client_bootstrap",
  ]
}

variable "allow_kms_decrypt_without_key_arns" {
  description = "If true, KMS decrypt uses Resource=* constrained by Secrets Manager via-service and SecretARN encryption context when exact key ARNs are not known."
  type        = bool
  default     = false
}

variable "attach_secret_read_policy_to_swg_read_role" {
  description = "Whether to attach the generated Secrets Manager/KMS read policy to the SWG read role when it is created here."
  type        = bool
  default     = true
}

variable "attach_secret_read_policy_to_resource_access_role" {
  description = "Whether to attach the generated Secrets Manager/KMS read policy to the SWG resource-access role when it is created here."
  type        = bool
  default     = true
}

variable "attach_security_admin_policy" {
  description = "Whether to attach generated non-secret KMS and Secrets Manager administration scaffolding to the security-admin role."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to IAM resources."
  type        = map(string)
  default     = {}
}
