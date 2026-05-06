variable "aws_region" {
  description = "AWS region for this standalone RBI data/security stack."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
  default     = "rbi"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "prod"
}

variable "kms_admin_principal_arns" {
  description = "RBI administrator principals allowed to administer the data KMS key."
  type        = list(string)
  default     = []
}

variable "swg_read_role_arns" {
  description = "Cross-account SWG role ARNs allowed to read RBI-owned secret values through Secrets Manager and KMS."
  type        = list(string)
  default     = []
}

variable "rbi_secret_metadata" {
  description = "RBI-owned Secrets Manager metadata. Values are intentionally omitted and must be populated outside Terraform."
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
  default = {
    session_token_signing = {
      description = "RBI session authority signing secret metadata placeholder. Populate the value outside Terraform."
      tags = {
        RbiUse = "session-authority"
      }
    }
    turn_shared_secret = {
      description = "RBI TURN shared secret metadata placeholder. Populate the value outside Terraform."
      tags = {
        RbiUse = "turn"
      }
    }
    pool_worker_shared_secret = {
      description = "RBI worker pool shared secret metadata placeholder. Populate the value outside Terraform."
      tags = {
        RbiUse = "worker-pool"
      }
    }
    rbi_internal_shared_secret = {
      description                     = "RBI internal service-to-service shared secret metadata placeholder. Populate the value outside Terraform."
      inherit_default_read_principals = false
      tags = {
        RbiUse = "internal-service-auth"
      }
    }
    host_agent_shared_secret = {
      description = "RBI host agent shared secret metadata placeholder. Populate the value outside Terraform."
      tags = {
        RbiUse = "host-agent"
      }
    }
    swg_handoff_shared_secret = {
      description = "SWG to RBI handoff shared secret metadata placeholder. Populate the value outside Terraform."
      tags = {
        RbiUse = "swg-handoff"
      }
    }
    mtls_client_bootstrap = {
      description = "mTLS client bootstrap secret metadata placeholder. Populate the value outside Terraform."
      tags = {
        RbiUse = "mtls"
      }
    }
  }
}

variable "rotation_lambda_arns" {
  description = "Optional externally built rotation Lambda ARNs keyed by rbi_secret_metadata key."
  type        = map(string)
  default     = {}
}

variable "default_rotation_days" {
  description = "Default rotation period used when a rotation Lambda ARN is supplied."
  type        = number
  default     = 30
}

variable "public_certificate_domain_name" {
  description = "Optional public ACM certificate domain name for RBI endpoints."
  type        = string
  default     = ""
}

variable "public_certificate_subject_alternative_names" {
  description = "Subject alternative names for the optional public ACM certificate."
  type        = list(string)
  default     = []
}

variable "public_certificate_hosted_zone_id" {
  description = "Optional Route53 public hosted zone ID for ACM DNS validation records."
  type        = string
  default     = ""
}

variable "wait_for_public_certificate_validation" {
  description = "Whether Terraform should wait for ACM public certificate validation."
  type        = bool
  default     = false
}

variable "private_cas" {
  description = "ACM Private CA metadata used as RBI mTLS trust anchors."
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
  default = {
    rbi_client_trust = {
      type                            = "ROOT"
      key_algorithm                   = "RSA_2048"
      signing_algorithm               = "SHA256WITHRSA"
      usage_mode                      = "GENERAL_PURPOSE"
      permanent_deletion_time_in_days = 30
      subject = {
        common_name         = "rbi-prod-client-trust-root"
        organization        = "RBI"
        organizational_unit = "Remote Browser Isolation"
        country             = "US"
      }
      tags = {
        RbiUse = "mtls-client-trust"
      }
    }
  }
}

variable "private_ca_permissions" {
  description = "Optional ACM PCA permissions for cross-account mTLS issuance principals."
  type = map(object({
    ca_key    = string
    principal = string
    actions   = optional(list(string), ["IssueCertificate", "GetCertificate", "ListPermissions"])
  }))
  default = {}
}

variable "trust_bundles" {
  description = "Non-sensitive trust bundle metadata. PEM content and private keys are intentionally excluded."
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
  default = {
    swg_client_trust = {
      description          = "RBI mTLS trust bundle metadata for SWG client authentication."
      pca_key              = "rbi_client_trust"
      version              = "v1"
      create_ssm_parameter = true
      tags = {
        RbiUse = "swg-client-mtls"
      }
    }
  }
}

variable "observability_event_target_arns" {
  description = "Optional SNS topic, SQS queue, or Lambda ARNs that receive security audit EventBridge events."
  type        = list(string)
  default     = []
}

variable "observability_log_retention_days" {
  description = "CloudWatch retention for rotation placeholder log groups."
  type        = number
  default     = 180
}

variable "observability_log_group_kms_key_id" {
  description = "Optional KMS key ID for CloudWatch log groups. The selected key policy must allow CloudWatch Logs."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
