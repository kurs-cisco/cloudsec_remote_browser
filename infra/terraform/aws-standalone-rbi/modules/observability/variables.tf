variable "log_groups" {
  description = "CloudWatch log groups for security, secrets, mTLS, or rotation Lambda placeholders."
  type = map(object({
    name              = optional(string)
    retention_in_days = optional(number)
    kms_key_id        = optional(string)
    skip_destroy      = optional(bool)
    tags              = optional(map(string), {})
  }))
  default = {}
}

variable "event_rules" {
  description = "EventBridge audit rules for security-sensitive AWS API activity."
  type = map(object({
    name          = optional(string)
    description   = optional(string)
    event_pattern = string
    state         = optional(string)
    target_arns   = optional(list(string), [])
    tags          = optional(map(string), {})
  }))
  default = {}
}

variable "tags" {
  description = "Tags applied to observability resources."
  type        = map(string)
  default     = {}
}
