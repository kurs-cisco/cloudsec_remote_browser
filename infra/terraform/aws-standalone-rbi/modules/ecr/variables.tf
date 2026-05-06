variable "name_prefix" {
  description = "Prefix prepended to all ECR repository names."
  type        = string
}

variable "repositories" {
  description = "ECR repositories keyed by logical name."
  type = map(object({
    force_delete         = optional(bool, false)
    image_tag_mutability = optional(string, "IMMUTABLE")
    scan_on_push         = optional(bool, true)
    encryption_type      = optional(string, "AES256")
    kms_key_arn          = optional(string)
    max_image_count      = optional(number, 50)
  }))
}

variable "tags" {
  description = "Tags applied to ECR resources."
  type        = map(string)
  default     = {}
}
