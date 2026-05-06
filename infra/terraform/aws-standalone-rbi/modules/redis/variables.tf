variable "name" {
  description = "Name for Redis resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for Redis security group."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR used to constrain Redis egress."
  type        = string
}

variable "subnet_ids" {
  description = "Private data subnet IDs for Redis."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to connect to Redis."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDR ranges allowed to connect to Redis. Keep scoped to private workload CIDRs."
  type        = list(string)
  default     = []
}

variable "node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t4g.micro"
}

variable "node_count" {
  description = "Number of Redis cache nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1
    error_message = "node_count must be at least 1."
  }
}

variable "engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.1"
}

variable "parameter_group_name" {
  description = "Optional Redis parameter group name."
  type        = string
  default     = null
}

variable "port" {
  description = "Redis port."
  type        = number
  default     = 6379
}

variable "kms_key_id" {
  description = "Optional KMS key ID or ARN for at-rest encryption. KMS key creation is out of scope."
  type        = string
  default     = null
}

variable "user_group_ids" {
  description = "Optional externally managed Redis user group IDs. User/password management is intentionally out of scope."
  type        = list(string)
  default     = []
}

variable "snapshot_retention_limit" {
  description = "Number of days to retain automatic Redis snapshots."
  type        = number
  default     = 7
}

variable "maintenance_window" {
  description = "Preferred maintenance window."
  type        = string
  default     = "sun:07:00-sun:08:00"
}

variable "apply_immediately" {
  description = "Whether Redis changes apply immediately."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to Redis resources."
  type        = map(string)
  default     = {}
}
