data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  resource_name_prefix = "${var.project_name}-${var.environment}-data"
  secret_name_prefix   = "${var.project_name}/${var.environment}/data"

  provider_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    Stack       = "aws-standalone-rbi-data"
    Owner       = "rbi"
  })

  common_tags = merge(local.provider_tags, {
    TerraformRoot = "envs/prod/us-east-1/data"
  })

  secret_names = {
    for secret_key, secret in var.rbi_secret_metadata :
    secret_key => secret.name != null ? secret.name : "${local.secret_name_prefix}/${secret_key}"
  }

  secret_arn_patterns = [
    for secret_name in values(local.secret_names) :
    "arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${secret_name}-*"
  ]

  rotation_placeholders = {
    for secret_key in keys(var.rbi_secret_metadata) :
    secret_key => {
      secret_key               = secret_key
      create_iam_role          = true
      rotation_lambda_arn      = lookup(var.rotation_lambda_arns, secret_key, null)
      automatically_after_days = var.default_rotation_days
    }
  }

  public_certificates = var.public_certificate_domain_name == "" ? {} : {
    public_endpoint = {
      domain_name               = var.public_certificate_domain_name
      subject_alternative_names = var.public_certificate_subject_alternative_names
      hosted_zone_id            = var.public_certificate_hosted_zone_id != "" ? var.public_certificate_hosted_zone_id : null
      create_route53_records    = var.public_certificate_hosted_zone_id != ""
      wait_for_validation       = var.wait_for_public_certificate_validation
      tags = {
        RbiUse = "public-endpoint"
      }
    }
  }

  rotation_log_groups = {
    for rotation_key in keys(local.rotation_placeholders) :
    "rotation_${rotation_key}" => {
      name              = "/aws/lambda/${local.resource_name_prefix}-${rotation_key}-rotation"
      retention_in_days = var.observability_log_retention_days
      kms_key_id        = var.observability_log_group_kms_key_id
      tags = {
        RbiUse = "rotation-placeholder"
      }
    }
  }

  observability_event_rules = {
    secrets_manager_audit = {
      name        = "${local.resource_name_prefix}-secrets-audit"
      description = "Audit RBI Secrets Manager secret version and rotation API activity."
      event_pattern = jsonencode({
        source      = ["aws.secretsmanager"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["secretsmanager.amazonaws.com"]
          eventName = [
            "CancelRotateSecret",
            "DeleteSecret",
            "PutSecretValue",
            "RestoreSecret",
            "RotateSecret",
            "UpdateSecret",
            "UpdateSecretVersionStage",
          ]
        }
      })
      target_arns = var.observability_event_target_arns
      tags = {
        RbiUse = "secrets-audit"
      }
    }

    kms_secrets_audit = {
      name        = "${local.resource_name_prefix}-kms-audit"
      description = "Audit KMS decrypt operations for RBI secret material."
      event_pattern = jsonencode({
        source      = ["aws.kms"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["kms.amazonaws.com"]
          eventName   = ["Decrypt", "GenerateDataKey", "Encrypt"]
        }
      })
      target_arns = var.observability_event_target_arns
      tags = {
        RbiUse = "kms-audit"
      }
    }

    mtls_certificate_audit = {
      name        = "${local.resource_name_prefix}-mtls-audit"
      description = "Audit ACM and ACM PCA API activity for RBI mTLS metadata."
      event_pattern = jsonencode({
        source      = ["aws.acm", "aws.acm-pca"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["acm.amazonaws.com", "acm-pca.amazonaws.com"]
        }
      })
      target_arns = var.observability_event_target_arns
      tags = {
        RbiUse = "mtls-audit"
      }
    }
  }
}

module "kms" {
  source = "../../../../modules/kms"

  name        = "secrets"
  environment = var.environment
  description = "RBI ${var.environment} data key for Secrets Manager metadata and future rotation workflows."
  alias_names = ["alias/${local.resource_name_prefix}-secrets"]

  admin_principal_arns         = var.kms_admin_principal_arns
  decrypt_principal_arns       = var.swg_read_role_arns
  allowed_secret_arn_patterns  = local.secret_arn_patterns
  deletion_window_in_days      = 30
  enable_key_rotation          = true
  source_policy_documents      = []
  secret_writer_principal_arns = []

  tags = local.common_tags
}

module "secrets" {
  source = "../../../../modules/secrets"

  secret_name_prefix          = local.secret_name_prefix
  resource_name_prefix        = local.resource_name_prefix
  default_kms_key_id          = module.kms.key_arn
  default_read_principal_arns = var.swg_read_role_arns
  secrets                     = var.rbi_secret_metadata
  rotation_placeholders       = local.rotation_placeholders
  rotation_kms_key_arn        = module.kms.key_arn

  tags = local.common_tags
}

module "mtls" {
  source = "../../../../modules/mtls"

  public_certificates           = local.public_certificates
  private_cas                   = var.private_cas
  private_ca_permissions        = var.private_ca_permissions
  trust_bundles                 = var.trust_bundles
  trust_bundle_parameter_prefix = "/${var.project_name}/${var.environment}/mtls/trust-bundles"

  tags = local.common_tags
}

module "observability" {
  source = "../../../../modules/observability"

  log_groups  = local.rotation_log_groups
  event_rules = local.observability_event_rules

  tags = local.common_tags
}
