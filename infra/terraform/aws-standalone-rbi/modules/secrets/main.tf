data "aws_partition" "current" {}

locals {
  secret_name_prefix = trimsuffix(var.secret_name_prefix, "/")

  read_principals_by_secret = {
    for secret_key, secret in var.secrets :
    secret_key => distinct(compact(concat(
      coalesce(secret.inherit_default_read_principals, true) ? var.default_read_principal_arns : [],
      secret.read_principal_arns != null ? secret.read_principal_arns : []
    )))
  }

  rotation_role_placeholders = {
    for placeholder_key, placeholder in var.rotation_placeholders :
    placeholder_key => placeholder
    if coalesce(placeholder.create_iam_role, true)
  }

  enabled_rotation_placeholders = {
    for placeholder_key, placeholder in var.rotation_placeholders :
    placeholder_key => placeholder
    if placeholder.rotation_lambda_arn != null && placeholder.rotation_lambda_arn != ""
  }
}

resource "aws_secretsmanager_secret" "this" {
  for_each = var.secrets

  name        = each.value.name != null ? each.value.name : "${local.secret_name_prefix}/${each.key}"
  description = each.value.description != null ? each.value.description : "RBI-owned metadata placeholder for ${each.key}; secret value is managed outside Terraform."
  kms_key_id  = each.value.kms_key_id != null ? each.value.kms_key_id : var.default_kms_key_id

  recovery_window_in_days        = each.value.recovery_window_in_days != null ? each.value.recovery_window_in_days : var.default_recovery_window_in_days
  force_overwrite_replica_secret = coalesce(each.value.force_overwrite_replica_secret, false)

  dynamic "replica" {
    for_each = each.value.replica_regions != null ? each.value.replica_regions : []

    content {
      region     = replica.value.region
      kms_key_id = replica.value.kms_key_id
    }
  }

  tags = merge(
    var.tags,
    each.value.tags != null ? each.value.tags : {},
    {
      Module                    = "secrets"
      RbiSecretOwner            = "rbi"
      SecretMaterialManagedBy   = "out-of-band"
      TerraformStoresPlaintext  = "false"
      TerraformCreatesVersion   = "false"
      CrossAccountPolicyManaged = "true"
    }
  )
}

data "aws_iam_policy_document" "secret_resource" {
  for_each = aws_secretsmanager_secret.this

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    actions = [
      "secretsmanager:*",
    ]
    resources = [each.value.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = length(local.read_principals_by_secret[each.key]) > 0 ? [1] : []

    content {
      sid    = "AllowSwgReadPrincipals"
      effect = "Allow"
      actions = [
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:ListSecretVersionIds",
      ]
      resources = [each.value.arn]

      principals {
        type        = "AWS"
        identifiers = local.read_principals_by_secret[each.key]
      }
    }
  }
}

resource "aws_secretsmanager_secret_policy" "this" {
  for_each = aws_secretsmanager_secret.this

  secret_arn          = each.value.arn
  policy              = data.aws_iam_policy_document.secret_resource[each.key].json
  block_public_policy = true
}

data "aws_iam_policy_document" "rotation_assume_role" {
  statement {
    sid     = "AllowLambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rotation" {
  for_each = local.rotation_role_placeholders

  name               = each.value.role_name != null ? each.value.role_name : substr("${var.resource_name_prefix}-${replace(each.key, "/[^A-Za-z0-9+=,.@_-]/", "-")}-rotation", 0, 64)
  assume_role_policy = data.aws_iam_policy_document.rotation_assume_role.json

  tags = merge(
    var.tags,
    each.value.tags != null ? each.value.tags : {},
    {
      Module                   = "secrets"
      RotationLambdaScaffold   = "true"
      TerraformStoresPlaintext = "false"
    }
  )
}

resource "aws_iam_role_policy_attachment" "rotation_basic_execution" {
  for_each = aws_iam_role.rotation

  role       = each.value.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "rotation" {
  for_each = aws_iam_role.rotation

  statement {
    sid    = "AllowRotationSecretMetadataAndVersions"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecretVersionStage",
    ]
    resources = [aws_secretsmanager_secret.this[var.rotation_placeholders[each.key].secret_key].arn]
  }

  statement {
    sid       = "AllowRandomPasswordForRotation"
    effect    = "Allow"
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.rotation_kms_key_arn != null ? [1] : []

    content {
      sid    = "AllowRotationKmsUse"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey",
        "kms:GenerateDataKeyWithoutPlaintext",
      ]
      resources = [var.rotation_kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "rotation" {
  for_each = aws_iam_role.rotation

  name   = "rotation-placeholder"
  role   = each.value.id
  policy = data.aws_iam_policy_document.rotation[each.key].json
}

resource "aws_lambda_permission" "allow_secretsmanager_rotation" {
  for_each = local.enabled_rotation_placeholders

  statement_id  = substr("AllowSecretsManager-${replace(each.key, "/[^A-Za-z0-9_-]/", "-")}", 0, 100)
  action        = "lambda:InvokeFunction"
  function_name = each.value.rotation_lambda_arn
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.this[each.value.secret_key].arn
}

resource "aws_secretsmanager_secret_rotation" "this" {
  for_each = local.enabled_rotation_placeholders

  secret_id           = aws_secretsmanager_secret.this[each.value.secret_key].id
  rotation_lambda_arn = each.value.rotation_lambda_arn
  rotate_immediately  = coalesce(each.value.rotate_immediately, false)

  rotation_rules {
    automatically_after_days = each.value.automatically_after_days
    schedule_expression      = each.value.schedule_expression
    duration                 = each.value.duration
  }

  depends_on = [aws_lambda_permission.allow_secretsmanager_rotation]
}
