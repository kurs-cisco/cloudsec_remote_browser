data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  account_root_arn           = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
  secretsmanager_via_service = "secretsmanager.${data.aws_region.current.name}.${data.aws_partition.current.dns_suffix}"

  normalized_alias_names = {
    for alias_name in var.alias_names :
    alias_name => startswith(alias_name, "alias/") ? alias_name : "alias/${alias_name}"
  }
}

data "aws_iam_policy_document" "this" {
  source_policy_documents = var.source_policy_documents

  statement {
    sid       = "EnableRootAccountPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.account_root_arn]
    }
  }

  dynamic "statement" {
    for_each = length(var.admin_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowRbiKeyAdministrators"
      effect = "Allow"
      actions = [
        "kms:CancelKeyDeletion",
        "kms:Create*",
        "kms:Delete*",
        "kms:Describe*",
        "kms:Disable*",
        "kms:Enable*",
        "kms:Get*",
        "kms:List*",
        "kms:Put*",
        "kms:Revoke*",
        "kms:ScheduleKeyDeletion",
        "kms:TagResource",
        "kms:UntagResource",
        "kms:Update*",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.admin_principal_arns
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.decrypt_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowSecretsManagerDecryptForReadPrincipals"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.decrypt_principal_arns
      }

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = [local.secretsmanager_via_service]
      }

      dynamic "condition" {
        for_each = length(var.allowed_secret_arn_patterns) > 0 ? [1] : []

        content {
          test     = "ArnLike"
          variable = "kms:EncryptionContext:SecretARN"
          values   = var.allowed_secret_arn_patterns
        }
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.secret_writer_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowSecretsManagerEncryptDecryptForWriterPrincipals"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:ReEncryptFrom",
        "kms:ReEncryptTo",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.secret_writer_principal_arns
      }

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = [local.secretsmanager_via_service]
      }

      dynamic "condition" {
        for_each = length(var.allowed_secret_arn_patterns) > 0 ? [1] : []

        content {
          test     = "ArnLike"
          variable = "kms:EncryptionContext:SecretARN"
          values   = var.allowed_secret_arn_patterns
        }
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description              = var.description != null ? var.description : "RBI ${var.environment} ${var.name} key"
  deletion_window_in_days  = var.deletion_window_in_days
  enable_key_rotation      = var.enable_key_rotation
  key_usage                = var.key_usage
  customer_master_key_spec = var.customer_master_key_spec
  multi_region             = var.multi_region
  policy                   = data.aws_iam_policy_document.this.json

  tags = merge(var.tags, {
    Name        = "rbi-${var.environment}-${var.name}"
    Module      = "kms"
    Environment = var.environment
  })
}

resource "aws_kms_alias" "this" {
  for_each = local.normalized_alias_names

  name          = each.value
  target_key_id = aws_kms_key.this.key_id
}
