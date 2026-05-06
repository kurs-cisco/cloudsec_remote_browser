variable "public_certificates" {
  description = "Public ACM certificates for RBI endpoints. DNS validation records are optional."
  type = map(object({
    domain_name               = string
    subject_alternative_names = optional(list(string), [])
    validation_method         = optional(string)
    hosted_zone_id            = optional(string)
    create_route53_records    = optional(bool)
    wait_for_validation       = optional(bool)
    tags                      = optional(map(string), {})
  }))
  default = {}
}

variable "private_cas" {
  description = "ACM Private CA metadata for mTLS trust anchors. CA certificates are not imported by this module."
  type = map(object({
    type                            = optional(string)
    key_algorithm                   = optional(string)
    signing_algorithm               = optional(string)
    usage_mode                      = optional(string)
    permanent_deletion_time_in_days = optional(number)
    subject = object({
      common_name         = string
      organization        = optional(string)
      organizational_unit = optional(string)
      country             = optional(string)
      state               = optional(string)
      locality            = optional(string)
    })
    tags = optional(map(string), {})
  }))
  default = {}
}

variable "private_ca_permissions" {
  description = "Optional ACM PCA permissions for external or cross-account certificate issuance principals."
  type = map(object({
    ca_key    = string
    principal = string
    actions   = optional(list(string), ["IssueCertificate", "GetCertificate", "ListPermissions"])
  }))
  default = {}
}

variable "trust_bundle_parameter_prefix" {
  description = "SSM Parameter Store prefix for non-sensitive trust bundle metadata."
  type        = string
  default     = "/rbi/mtls/trust-bundles"
}

variable "trust_bundles" {
  description = "Non-sensitive trust bundle metadata. PEM material and private keys are intentionally excluded."
  type = map(object({
    description          = optional(string)
    pca_key              = optional(string)
    ca_arn               = optional(string)
    s3_uri               = optional(string)
    version              = optional(string)
    create_ssm_parameter = optional(bool)
    parameter_name       = optional(string)
    tags                 = optional(map(string), {})
  }))
  default = {}
}

variable "tags" {
  description = "Tags applied to ACM, ACM PCA, and SSM metadata resources."
  type        = map(string)
  default     = {}
}
