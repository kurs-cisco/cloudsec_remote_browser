variable "name" {
  description = "Short KMS key purpose name used for tagging only."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
}

variable "description" {
  description = "Optional KMS key description."
  type        = string
  default     = null
}

variable "deletion_window_in_days" {
  description = "Waiting period before deleting the KMS key."
  type        = number
  default     = 30
}

variable "enable_key_rotation" {
  description = "Whether AWS KMS automatic key rotation is enabled."
  type        = bool
  default     = true
}

variable "multi_region" {
  description = "Whether the KMS key is a multi-Region key."
  type        = bool
  default     = false
}

variable "key_usage" {
  description = "KMS key usage."
  type        = string
  default     = "ENCRYPT_DECRYPT"
}

variable "customer_master_key_spec" {
  description = "KMS key spec."
  type        = string
  default     = "SYMMETRIC_DEFAULT"
}

variable "alias_names" {
  description = "KMS aliases to create. Values may include or omit the alias/ prefix."
  type        = set(string)
  default     = []
}

variable "admin_principal_arns" {
  description = "Additional RBI key administrator principal ARNs."
  type        = list(string)
  default     = []
}

variable "decrypt_principal_arns" {
  description = "Cross-account or external principal ARNs allowed to decrypt Secrets Manager values through this key."
  type        = list(string)
  default     = []
}

variable "secret_writer_principal_arns" {
  description = "Principal ARNs, such as future rotation roles, allowed to encrypt/decrypt Secrets Manager values through this key."
  type        = list(string)
  default     = []
}

variable "allowed_secret_arn_patterns" {
  description = "Secret ARN patterns allowed in the KMS encryption context for cross-account read/write grants."
  type        = list(string)
  default     = []
}

variable "source_policy_documents" {
  description = "Additional KMS key policy documents to merge into the generated policy."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to KMS resources."
  type        = map(string)
  default     = {}
}
