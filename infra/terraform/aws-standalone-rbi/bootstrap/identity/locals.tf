data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  provider_tags = merge(
    var.tags,
    {
      Project     = var.project_name
      Environment = var.environment
      Stack       = "aws-standalone-rbi-identity"
      ManagedBy   = "terraform"
    }
  )

  state_bucket_arns = distinct(compact(concat(
    var.terraform_state_bucket_arns,
    var.terraform_state_bucket_name != null ? ["arn:${data.aws_partition.current.partition}:s3:::${var.terraform_state_bucket_name}"] : []
  )))

  state_lock_table_arns = distinct(compact(concat(
    var.terraform_lock_table_arns,
    var.terraform_lock_table_name != null ? ["arn:${data.aws_partition.current.partition}:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.terraform_lock_table_name}"] : []
  )))

  terraform_state_key_prefixes = length(var.terraform_state_key_prefixes) > 0 ? var.terraform_state_key_prefixes : [
    "${var.environment}/${var.aws_region}/"
  ]
}
