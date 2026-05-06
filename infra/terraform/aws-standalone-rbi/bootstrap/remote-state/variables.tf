variable "project_name" {
  description = "Short project name used in bootstrap resource names."
  type        = string
  default     = "cloudsec-rbi"
}

variable "environment" {
  description = "Environment name for the Terraform state backend."
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS region that hosts the Terraform state bucket and lock table."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Optional explicit S3 bucket name for Terraform state. If null, a deterministic name is derived from project, account, environment, and region."
  type        = string
  default     = null
}

variable "lock_table_name" {
  description = "Optional explicit DynamoDB table name for Terraform state locking."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Whether to allow destroying a non-empty state bucket. Keep false for production."
  type        = bool
  default     = false
}

variable "enable_lock_table_deletion_protection" {
  description = "Whether DynamoDB deletion protection is enabled for the lock table."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to bootstrap resources."
  type        = map(string)
  default     = {}
}
