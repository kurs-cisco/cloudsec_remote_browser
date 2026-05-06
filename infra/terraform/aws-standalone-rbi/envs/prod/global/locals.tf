locals {
  name_prefix = "${var.project_name}-${var.environment}"

  tags = merge(
    var.tags,
    {
      Project     = var.project_name
      Environment = var.environment
      Component   = "global-foundation"
      ManagedBy   = "terraform"
    }
  )
}
