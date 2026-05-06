data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  current_account_id = data.aws_caller_identity.current.account_id
  partition          = data.aws_partition.current.partition
  dns_suffix         = data.aws_partition.current.dns_suffix

  rbi_account_id = coalesce(var.rbi_account_id, local.current_account_id)
  swg_account_id = coalesce(var.swg_account_id, local.current_account_id)

  current_account_root_arn = "arn:${local.partition}:iam::${local.current_account_id}:root"
  swg_account_root_arn     = "arn:${local.partition}:iam::${local.swg_account_id}:root"

  role_path         = var.role_path == "" ? "/" : (startswith(var.role_path, "/") ? var.role_path : "/${var.role_path}")
  role_path_clean   = trim(local.role_path, "/")
  role_path_for_arn = local.role_path_clean == "" ? "" : "${local.role_path_clean}/"

  deploy_role_name              = coalesce(var.deploy_role_name, "${var.role_name_prefix}-${var.environment}-deploy")
  security_admin_role_name      = coalesce(var.security_admin_role_name, "${var.role_name_prefix}-${var.environment}-security-admin")
  swg_read_role_name            = coalesce(var.swg_read_role_name, "swg-${var.environment}-${var.role_name_prefix}-secret-reader")
  swg_resource_access_role_name = coalesce(var.swg_resource_access_role_name, "swg-${var.environment}-${var.role_name_prefix}-resource-access")

  deploy_role_arn_expected              = "arn:${local.partition}:iam::${local.rbi_account_id}:role/${local.role_path_for_arn}${local.deploy_role_name}"
  security_admin_role_arn_expected      = "arn:${local.partition}:iam::${local.rbi_account_id}:role/${local.role_path_for_arn}${local.security_admin_role_name}"
  swg_read_role_arn_expected            = "arn:${local.partition}:iam::${local.swg_account_id}:role/${local.role_path_for_arn}${local.swg_read_role_name}"
  swg_resource_access_role_arn_expected = "arn:${local.partition}:iam::${local.swg_account_id}:role/${local.role_path_for_arn}${local.swg_resource_access_role_name}"

  deploy_trusted_principal_arns              = length(var.deploy_trusted_principal_arns) > 0 ? var.deploy_trusted_principal_arns : [local.current_account_root_arn]
  security_admin_trusted_principal_arns      = length(var.security_admin_trusted_principal_arns) > 0 ? var.security_admin_trusted_principal_arns : [local.current_account_root_arn]
  swg_read_trusted_principal_arns            = length(var.swg_read_trusted_principal_arns) > 0 ? var.swg_read_trusted_principal_arns : [local.swg_account_root_arn]
  swg_resource_access_trusted_principal_arns = length(var.swg_resource_access_trusted_principal_arns) > 0 ? var.swg_resource_access_trusted_principal_arns : [local.swg_account_root_arn]

  assume_role_specs = {
    deploy = {
      trusted_principal_arns = local.deploy_trusted_principal_arns
      external_ids           = var.deploy_role_external_ids
      require_mfa            = var.require_mfa_for_deploy_role
    }
    security_admin = {
      trusted_principal_arns = local.security_admin_trusted_principal_arns
      external_ids           = var.security_admin_external_ids
      require_mfa            = var.require_mfa_for_security_admin_role
    }
    swg_read = {
      trusted_principal_arns = local.swg_read_trusted_principal_arns
      external_ids           = var.swg_read_external_ids
      require_mfa            = false
    }
    swg_resource_access = {
      trusted_principal_arns = local.swg_resource_access_trusted_principal_arns
      external_ids           = var.swg_resource_access_external_ids
      require_mfa            = false
    }
  }

  secret_name_prefix = trimsuffix(coalesce(var.secret_name_prefix, "${var.project_name}/${var.environment}/data"), "/")

  default_secret_arn_patterns = var.enable_default_secret_arn_patterns ? [
    for secret_key in var.default_secret_keys :
    "arn:${local.partition}:secretsmanager:${var.aws_region}:${local.rbi_account_id}:secret:${local.secret_name_prefix}/${secret_key}-*"
  ] : []

  secret_read_resources = distinct(compact(concat(
    var.secret_arns,
    var.secret_arn_patterns,
    local.default_secret_arn_patterns
  )))

  kms_decrypt_resources = length(var.kms_key_arns) > 0 ? var.kms_key_arns : (
    var.allow_kms_decrypt_without_key_arns && length(local.secret_read_resources) > 0 ? ["*"] : []
  )

  has_secret_read_policy    = length(local.secret_read_resources) > 0
  has_kms_decrypt_policy    = length(local.secret_read_resources) > 0 && length(local.kms_decrypt_resources) > 0
  has_security_admin_policy = var.attach_security_admin_policy && (length(var.kms_key_arns) > 0 || length(local.secret_read_resources) > 0)
  has_deploy_state_policy   = var.attach_deploy_state_policy && (length(var.terraform_state_bucket_arns) > 0 || length(var.terraform_lock_table_arns) > 0)
  state_object_arn_prefixes = length(var.terraform_state_key_prefixes) > 0 ? var.terraform_state_key_prefixes : ["*"]
  state_object_resource_arns = flatten([
    for bucket_arn in var.terraform_state_bucket_arns : [
      for key_prefix in local.state_object_arn_prefixes :
      "${trimsuffix(bucket_arn, "/")}/${trimprefix(key_prefix, "/")}${key_prefix == "*" ? "" : "*"}"
    ]
  ])

  common_tags = merge(
    var.tags,
    {
      Project     = var.project_name
      Environment = var.environment
      Module      = "bootstrap-iam"
      ManagedBy   = "terraform"
    }
  )
}

resource "terraform_data" "validate_rbi_role_account" {
  input = local.rbi_account_id

  lifecycle {
    precondition {
      condition     = (!var.create_deploy_role && !var.create_security_admin_role) || local.rbi_account_id == local.current_account_id
      error_message = "This module can only create RBI deploy/security roles in the current provider account. Set create_deploy_role/create_security_admin_role to false and pass existing ARNs for cross-account use."
    }
  }
}

resource "terraform_data" "validate_swg_role_account" {
  input = local.swg_account_id

  lifecycle {
    precondition {
      condition     = (!var.create_swg_read_role && !var.create_swg_resource_access_role) || local.swg_account_id == local.current_account_id
      error_message = "This module can only create SWG roles in the current provider account. Set create_swg_read_role/create_swg_resource_access_role to false and pass external SWG role ARNs for cross-account use."
    }

    precondition {
      condition     = local.swg_account_id == local.current_account_id || var.create_swg_read_role || var.external_swg_read_role_arn != null
      error_message = "external_swg_read_role_arn is required when using a cross-account SWG read role that is not created in this provider account."
    }

    precondition {
      condition     = local.swg_account_id == local.current_account_id || var.create_swg_resource_access_role || var.external_swg_resource_access_role_arn != null
      error_message = "external_swg_resource_access_role_arn is required when using a cross-account SWG resource-access role that is not created in this provider account."
    }
  }
}

data "aws_iam_policy_document" "assume_role" {
  for_each = local.assume_role_specs

  statement {
    sid     = "AllowAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = each.value.trusted_principal_arns
    }

    dynamic "condition" {
      for_each = length(each.value.external_ids) > 0 ? [1] : []

      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = each.value.external_ids
      }
    }

    dynamic "condition" {
      for_each = each.value.require_mfa ? [1] : []

      content {
        test     = "Bool"
        variable = "aws:MultiFactorAuthPresent"
        values   = ["true"]
      }
    }
  }
}

resource "aws_iam_role" "deploy" {
  count = var.create_deploy_role ? 1 : 0

  name                  = local.deploy_role_name
  path                  = local.role_path
  assume_role_policy    = data.aws_iam_policy_document.assume_role["deploy"].json
  description           = "Standalone RBI Terraform deploy role for ${var.environment}."
  force_detach_policies = var.force_detach_policies
  max_session_duration  = var.max_session_duration
  permissions_boundary  = var.permissions_boundary_arn

  tags = merge(local.common_tags, {
    Name = local.deploy_role_name
    Role = "rbi-deploy"
  })

  depends_on = [terraform_data.validate_rbi_role_account]
}

resource "aws_iam_role" "security_admin" {
  count = var.create_security_admin_role ? 1 : 0

  name                  = local.security_admin_role_name
  path                  = local.role_path
  assume_role_policy    = data.aws_iam_policy_document.assume_role["security_admin"].json
  description           = "Standalone RBI security administrator role for ${var.environment}."
  force_detach_policies = var.force_detach_policies
  max_session_duration  = var.max_session_duration
  permissions_boundary  = var.permissions_boundary_arn

  tags = merge(local.common_tags, {
    Name = local.security_admin_role_name
    Role = "rbi-security-admin"
  })

  depends_on = [terraform_data.validate_rbi_role_account]
}

resource "aws_iam_role" "swg_read" {
  count = var.create_swg_read_role ? 1 : 0

  name                  = local.swg_read_role_name
  path                  = local.role_path
  assume_role_policy    = data.aws_iam_policy_document.assume_role["swg_read"].json
  description           = "SWG role allowed to read RBI secret material needed for integration."
  force_detach_policies = var.force_detach_policies
  max_session_duration  = var.max_session_duration
  permissions_boundary  = var.permissions_boundary_arn

  tags = merge(local.common_tags, {
    Name = local.swg_read_role_name
    Role = "swg-rbi-secret-reader"
  })

  depends_on = [terraform_data.validate_swg_role_account]
}

resource "aws_iam_role" "swg_resource_access" {
  count = var.create_swg_resource_access_role ? 1 : 0

  name                  = local.swg_resource_access_role_name
  path                  = local.role_path
  assume_role_policy    = data.aws_iam_policy_document.assume_role["swg_resource_access"].json
  description           = "SWG role reserved for RBI resource access wiring."
  force_detach_policies = var.force_detach_policies
  max_session_duration  = var.max_session_duration
  permissions_boundary  = var.permissions_boundary_arn

  tags = merge(local.common_tags, {
    Name = local.swg_resource_access_role_name
    Role = "swg-rbi-resource-access"
  })

  depends_on = [terraform_data.validate_swg_role_account]
}

data "aws_iam_role" "deploy" {
  count = !var.create_deploy_role && var.validate_existing_roles && local.rbi_account_id == local.current_account_id ? 1 : 0

  name = local.deploy_role_name
}

data "aws_iam_role" "security_admin" {
  count = !var.create_security_admin_role && var.validate_existing_roles && local.rbi_account_id == local.current_account_id ? 1 : 0

  name = local.security_admin_role_name
}

data "aws_iam_role" "swg_read" {
  count = !var.create_swg_read_role && var.validate_existing_roles && local.swg_account_id == local.current_account_id ? 1 : 0

  name = local.swg_read_role_name
}

data "aws_iam_role" "swg_resource_access" {
  count = !var.create_swg_resource_access_role && var.validate_existing_roles && local.swg_account_id == local.current_account_id ? 1 : 0

  name = local.swg_resource_access_role_name
}

locals {
  deploy_role_arn = var.create_deploy_role ? aws_iam_role.deploy[0].arn : try(
    data.aws_iam_role.deploy[0].arn,
    local.deploy_role_arn_expected
  )

  security_admin_role_arn = var.create_security_admin_role ? aws_iam_role.security_admin[0].arn : try(
    data.aws_iam_role.security_admin[0].arn,
    local.security_admin_role_arn_expected
  )

  swg_read_role_arn = var.create_swg_read_role ? aws_iam_role.swg_read[0].arn : coalesce(
    var.external_swg_read_role_arn,
    try(data.aws_iam_role.swg_read[0].arn, local.swg_read_role_arn_expected)
  )

  swg_resource_access_role_arn = var.create_swg_resource_access_role ? aws_iam_role.swg_resource_access[0].arn : coalesce(
    var.external_swg_resource_access_role_arn,
    try(data.aws_iam_role.swg_resource_access[0].arn, local.swg_resource_access_role_arn_expected)
  )

  deploy_assumable_role_arns = distinct(compact(concat(
    var.deploy_assumable_role_arns,
    var.allow_deploy_role_to_assume_security_admin ? [local.security_admin_role_arn_expected] : []
  )))

  data_root_kms_admin_principal_arns = [local.security_admin_role_arn]
  data_root_swg_read_role_arns = distinct(compact([
    local.swg_read_role_arn,
    var.attach_secret_read_policy_to_resource_access_role ? local.swg_resource_access_role_arn : null,
  ]))
}

data "aws_iam_policy_document" "deploy_state" {
  count = local.has_deploy_state_policy ? 1 : 0

  dynamic "statement" {
    for_each = length(var.terraform_state_bucket_arns) > 0 ? [1] : []

    content {
      sid    = "AllowTerraformStateBucketRead"
      effect = "Allow"
      actions = [
        "s3:GetBucketLocation",
        "s3:GetBucketVersioning",
        "s3:ListBucket",
      ]
      resources = var.terraform_state_bucket_arns

      dynamic "condition" {
        for_each = length(var.terraform_state_key_prefixes) > 0 ? [1] : []

        content {
          test     = "StringLike"
          variable = "s3:prefix"
          values = [
            for key_prefix in var.terraform_state_key_prefixes :
            key_prefix == "*" ? "*" : "${trimprefix(key_prefix, "/")}*"
          ]
        }
      }
    }
  }

  dynamic "statement" {
    for_each = length(local.state_object_resource_arns) > 0 ? [1] : []

    content {
      sid    = "AllowTerraformStateObjectReadWrite"
      effect = "Allow"
      actions = [
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
      ]
      resources = local.state_object_resource_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.terraform_lock_table_arns) > 0 ? [1] : []

    content {
      sid    = "AllowTerraformStateLocking"
      effect = "Allow"
      actions = [
        "dynamodb:DeleteItem",
        "dynamodb:DescribeTable",
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
      ]
      resources = var.terraform_lock_table_arns
    }
  }
}

resource "aws_iam_role_policy" "deploy_state" {
  count = var.create_deploy_role && local.has_deploy_state_policy ? 1 : 0

  name   = "terraform-state-access"
  role   = aws_iam_role.deploy[0].id
  policy = data.aws_iam_policy_document.deploy_state[0].json
}

data "aws_iam_policy_document" "deploy_assume" {
  count = length(local.deploy_assumable_role_arns) > 0 ? 1 : 0

  statement {
    sid       = "AllowAssumeBootstrapRoles"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = local.deploy_assumable_role_arns
  }
}

resource "aws_iam_role_policy" "deploy_assume" {
  count = var.create_deploy_role && length(local.deploy_assumable_role_arns) > 0 ? 1 : 0

  name   = "assume-bootstrap-roles"
  role   = aws_iam_role.deploy[0].id
  policy = data.aws_iam_policy_document.deploy_assume[0].json
}

data "aws_iam_policy_document" "secret_read" {
  count = local.has_secret_read_policy ? 1 : 0

  statement {
    sid    = "AllowRbiSecretValueRead"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = local.secret_read_resources
  }

  dynamic "statement" {
    for_each = local.has_kms_decrypt_policy ? [1] : []

    content {
      sid    = "AllowRbiSecretKmsDecrypt"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      resources = local.kms_decrypt_resources

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.aws_region}.${local.dns_suffix}"]
      }

      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:SecretARN"
        values   = local.secret_read_resources
      }
    }
  }
}

resource "aws_iam_role_policy" "swg_read_secret_read" {
  count = var.create_swg_read_role && var.attach_secret_read_policy_to_swg_read_role && local.has_secret_read_policy ? 1 : 0

  name   = "rbi-secret-read"
  role   = aws_iam_role.swg_read[0].id
  policy = data.aws_iam_policy_document.secret_read[0].json
}

resource "aws_iam_role_policy" "resource_access_secret_read" {
  count = var.create_swg_resource_access_role && var.attach_secret_read_policy_to_resource_access_role && local.has_secret_read_policy ? 1 : 0

  name   = "rbi-secret-read"
  role   = aws_iam_role.swg_resource_access[0].id
  policy = data.aws_iam_policy_document.secret_read[0].json
}

data "aws_iam_policy_document" "security_admin" {
  count = local.has_security_admin_policy ? 1 : 0

  dynamic "statement" {
    for_each = length(var.kms_key_arns) > 0 ? [1] : []

    content {
      sid    = "AllowKnownRbiKmsKeyAdministration"
      effect = "Allow"
      actions = [
        "kms:CancelKeyDeletion",
        "kms:CreateAlias",
        "kms:CreateGrant",
        "kms:DeleteAlias",
        "kms:Describe*",
        "kms:Disable*",
        "kms:Enable*",
        "kms:Get*",
        "kms:PutKeyPolicy",
        "kms:ReplicateKey",
        "kms:RetireGrant",
        "kms:RevokeGrant",
        "kms:ScheduleKeyDeletion",
        "kms:TagResource",
        "kms:UntagResource",
        "kms:Update*",
      ]
      resources = var.kms_key_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.kms_key_arns) > 0 ? [1] : []

    content {
      sid    = "AllowKmsDiscovery"
      effect = "Allow"
      actions = [
        "kms:ListAliases",
        "kms:ListKeys",
      ]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = length(local.secret_read_resources) > 0 ? [1] : []

    content {
      sid    = "AllowRbiSecretPolicyAndMetadataAdministration"
      effect = "Allow"
      actions = [
        "secretsmanager:DeleteResourcePolicy",
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetResourcePolicy",
        "secretsmanager:ListSecretVersionIds",
        "secretsmanager:PutResourcePolicy",
        "secretsmanager:TagResource",
        "secretsmanager:UntagResource",
      ]
      resources = local.secret_read_resources
    }
  }
}

resource "aws_iam_role_policy" "security_admin" {
  count = var.create_security_admin_role && local.has_security_admin_policy ? 1 : 0

  name   = "rbi-security-admin"
  role   = aws_iam_role.security_admin[0].id
  policy = data.aws_iam_policy_document.security_admin[0].json
}

resource "aws_iam_role_policy_attachment" "deploy_managed" {
  for_each = var.create_deploy_role ? toset(var.deploy_role_managed_policy_arns) : toset([])

  role       = aws_iam_role.deploy[0].name
  policy_arn = each.value
}

resource "aws_iam_role_policy_attachment" "security_admin_managed" {
  for_each = var.create_security_admin_role ? toset(var.security_admin_managed_policy_arns) : toset([])

  role       = aws_iam_role.security_admin[0].name
  policy_arn = each.value
}

resource "aws_iam_role_policy_attachment" "swg_read_managed" {
  for_each = var.create_swg_read_role ? toset(var.swg_read_managed_policy_arns) : toset([])

  role       = aws_iam_role.swg_read[0].name
  policy_arn = each.value
}

resource "aws_iam_role_policy_attachment" "swg_resource_access_managed" {
  for_each = var.create_swg_resource_access_role ? toset(var.swg_resource_access_managed_policy_arns) : toset([])

  role       = aws_iam_role.swg_resource_access[0].name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "deploy_additional" {
  for_each = var.create_deploy_role ? var.deploy_role_inline_policy_documents : {}

  name   = each.key
  role   = aws_iam_role.deploy[0].id
  policy = each.value
}

resource "aws_iam_role_policy" "security_admin_additional" {
  for_each = var.create_security_admin_role ? var.security_admin_inline_policy_documents : {}

  name   = each.key
  role   = aws_iam_role.security_admin[0].id
  policy = each.value
}

resource "aws_iam_role_policy" "swg_read_additional" {
  for_each = var.create_swg_read_role ? var.swg_read_inline_policy_documents : {}

  name   = each.key
  role   = aws_iam_role.swg_read[0].id
  policy = each.value
}

resource "aws_iam_role_policy" "swg_resource_access_additional" {
  for_each = var.create_swg_resource_access_role ? var.swg_resource_access_inline_policy_documents : {}

  name   = each.key
  role   = aws_iam_role.swg_resource_access[0].id
  policy = each.value
}
