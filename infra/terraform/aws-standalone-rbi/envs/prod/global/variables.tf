variable "project_name" {
  description = "Project name used for resource naming and tags."
  type        = string
  default     = "cloudsec-rbi"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS region for globally shared foundation resources."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Additional tags applied to all global foundation resources."
  type        = map(string)
  default     = {}
}

variable "ecr_repositories" {
  description = "ECR repositories to create for RBI service images."
  type = map(object({
    force_delete         = optional(bool, false)
    image_tag_mutability = optional(string, "IMMUTABLE")
    scan_on_push         = optional(bool, true)
    encryption_type      = optional(string, "AES256")
    kms_key_arn          = optional(string)
    max_image_count      = optional(number, 50)
  }))
  default = {
    control-plane     = {}
    media-gateway     = {}
    session-authority = {}
    worker            = {}
    file-broker       = {}
    clipboard-broker  = {}
  }

  validation {
    condition = alltrue([
      for repo in values(var.ecr_repositories) : contains(["MUTABLE", "IMMUTABLE"], repo.image_tag_mutability)
    ])
    error_message = "ECR image_tag_mutability must be MUTABLE or IMMUTABLE."
  }

  validation {
    condition = alltrue([
      for repo in values(var.ecr_repositories) : contains(["AES256", "KMS"], repo.encryption_type)
    ])
    error_message = "ECR encryption_type must be AES256 or KMS."
  }
}
