variable "secret_name_prefix" {
  description = "Secrets Manager name prefix for secrets whose names are not explicitly supplied."
  type        = string
}

variable "resource_name_prefix" {
  description = "AWS resource-safe prefix used for IAM role names and statement IDs."
  type        = string
}

variable "default_kms_key_id" {
  description = "Default KMS key ID or ARN for RBI-owned Secrets Manager metadata."
  type        = string
  default     = null
}

variable "default_recovery_window_in_days" {
  description = "Default recovery window for secret deletion."
  type        = number
  default     = 30
}

variable "default_read_principal_arns" {
  description = "Default cross-account SWG or external read principals for all secrets."
  type        = list(string)
  default     = []
}

variable "secrets" {
  description = "RBI-owned Secrets Manager metadata. This module never creates secret versions or plaintext values."
  type = map(object({
    name                           = optional(string)
    description                    = optional(string)
    kms_key_id                     = optional(string)
    recovery_window_in_days        = optional(number)
    force_overwrite_replica_secret = optional(bool)
    replica_regions = optional(list(object({
      region     = string
      kms_key_id = optional(string)
    })), [])
    inherit_default_read_principals = optional(bool, true)
    read_principal_arns             = optional(list(string), [])
    tags                            = optional(map(string), {})
  }))
  default = {}
}

variable "rotation_placeholders" {
  description = "Rotation Lambda scaffolding. Supplying rotation_lambda_arn enables Secrets Manager rotation; otherwise only IAM/log metadata can be prepared."
  type = map(object({
    secret_key                 = string
    role_name                  = optional(string)
    create_iam_role            = optional(bool)
    rotation_lambda_arn        = optional(string)
    automatically_after_days   = optional(number)
    schedule_expression        = optional(string)
    duration                   = optional(string)
    rotate_immediately         = optional(bool)
    hosted_rotation_lambda_arn = optional(string)
    tags                       = optional(map(string), {})
  }))
  default = {}
}

variable "rotation_kms_key_arn" {
  description = "KMS key ARN granted to generated rotation IAM role placeholders."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to Secrets Manager and IAM resources."
  type        = map(string)
  default     = {}
}
