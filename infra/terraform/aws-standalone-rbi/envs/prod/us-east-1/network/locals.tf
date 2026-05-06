locals {
  region_short       = replace(var.aws_region, "-", "")
  name_prefix        = "${var.project_name}-${var.environment}-${local.region_short}"
  secret_name_prefix = "${var.project_name}/${var.environment}/data"

  tags = merge(
    var.tags,
    {
      Project     = var.project_name
      Environment = var.environment
      Region      = var.aws_region
      Component   = "regional-network"
      ManagedBy   = "terraform"
    }
  )

  public_endpoint_alias_hosted_zone_id = var.public_endpoint_dns_hosted_zone_id != "" ? var.public_endpoint_dns_hosted_zone_id : var.public_dns_hosted_zone_id
  turn_alias_hosted_zone_id            = var.turn_dns_hosted_zone_id != "" ? var.turn_dns_hosted_zone_id : var.public_dns_hosted_zone_id
  use_existing_network                 = var.existing_vpc_id != ""
  effective_vpc_id                     = local.use_existing_network ? var.existing_vpc_id : module.network[0].vpc_id
  effective_vpc_cidr                   = local.use_existing_network ? var.existing_vpc_cidr : var.vpc_cidr
  effective_public_subnet_ids          = local.use_existing_network ? var.existing_public_subnet_ids : module.network[0].public_subnet_ids
  effective_private_subnet_ids         = local.use_existing_network ? var.existing_private_subnet_ids : module.network[0].private_subnet_ids
  effective_data_subnet_ids            = local.use_existing_network ? var.existing_data_subnet_ids : module.network[0].data_subnet_ids
  public_endpoint_host                 = var.public_endpoint_hostname != "" ? var.public_endpoint_hostname : module.ingress.alb_dns_name
  turn_host                            = var.turn_hostname != "" ? var.turn_hostname : module.turn.nlb_dns_name
  turn_alias_enabled                   = var.turn_hostname != "" && local.turn_alias_hosted_zone_id != ""
  worker_turn_private_dns_zone_name    = var.worker_turn_private_dns_zone_name != "" ? var.worker_turn_private_dns_zone_name : "internal.${local.public_endpoint_host}"
  worker_turn_private_dns_zone_enabled = var.turn_internal_nlb_enabled && var.worker_turn_hostname != "" && var.worker_turn_private_dns_hosted_zone_id == ""
  worker_turn_private_dns_zone_id      = var.worker_turn_private_dns_hosted_zone_id != "" ? var.worker_turn_private_dns_hosted_zone_id : try(aws_route53_zone.worker_turn_private[0].zone_id, "")
  worker_turn_alias_enabled            = var.turn_internal_nlb_enabled && var.worker_turn_hostname != "" && (var.worker_turn_private_dns_hosted_zone_id != "" || local.worker_turn_private_dns_zone_enabled)
  worker_turn_host                     = var.worker_turn_hostname != "" ? var.worker_turn_hostname : module.turn.internal_nlb_dns_name
  turn_shared_secret_id                = "${local.secret_name_prefix}/turn_shared_secret"
  turn_shared_secret_arn               = "arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${local.turn_shared_secret_id}-*"
}
