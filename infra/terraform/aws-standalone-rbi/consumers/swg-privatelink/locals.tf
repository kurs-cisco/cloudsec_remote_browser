locals {
  name = substr("${var.project_name}-${var.environment}-${var.name_suffix}-rbi-pl", 0, 64)

  endpoint_source_cidrs = length(var.allowed_client_cidrs) > 0 ? var.allowed_client_cidrs : var.vpc_cidr_blocks

  tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Stack       = "standalone-rbi-swg-consumer"
      Component   = "swg-privatelink-consumer"
    },
    var.tags,
  )
}
