locals {
  normalized_project = lower(replace(var.project_name, "_", "-"))
  normalized_env     = lower(replace(var.environment, "_", "-"))
  name_prefix        = "${local.normalized_project}-${local.normalized_env}"

  state_bucket_name = coalesce(
    var.state_bucket_name,
    "${local.name_prefix}-${data.aws_caller_identity.current.account_id}-${var.aws_region}-tfstate"
  )

  lock_table_name = coalesce(
    var.lock_table_name,
    "${local.name_prefix}-${var.aws_region}-terraform-locks"
  )

  tags = merge(
    var.tags,
    {
      Project     = var.project_name
      Environment = var.environment
      Component   = "terraform-state"
      ManagedBy   = "terraform"
    }
  )
}
