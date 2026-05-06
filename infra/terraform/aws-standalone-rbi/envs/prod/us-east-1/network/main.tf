data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

module "network" {
  count  = local.use_existing_network ? 0 : 1
  source = "../../../../modules/network"

  name                 = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  data_subnet_cidrs    = var.data_subnet_cidrs
  enable_nat_gateway   = var.enable_nat_gateway
  single_nat_gateway   = var.single_nat_gateway
  tags                 = local.tags
}

module "ingress" {
  source = "../../../../modules/ingress"

  name                                   = local.name_prefix
  vpc_id                                 = local.effective_vpc_id
  vpc_cidr                               = local.effective_vpc_cidr
  public_subnet_ids                      = local.effective_public_subnet_ids
  private_subnet_ids                     = local.effective_private_subnet_ids
  allowed_ingress_cidrs                  = var.viewer_ingress_cidrs
  certificate_arn                        = var.viewer_certificate_arn
  public_hostname                        = var.public_endpoint_hostname
  public_hosted_zone_id                  = local.public_endpoint_alias_hosted_zone_id
  privatelink_private_dns_hosted_zone_id = local.public_endpoint_alias_hosted_zone_id
  dns_alias_evaluate_target_health       = var.dns_alias_evaluate_target_health
  default_target_group_key               = "control-plane"
  listener_rules = {
    media-gateway = {
      priority         = 100
      target_group_key = "media-gateway"
      path_patterns = [
        "/v1/sessions*",
        "/gateway/*",
        "/ws/*",
      ]
    }
  }
  privatelink_private_dns_name    = var.privatelink_private_dns_name
  privatelink_allowed_principals  = var.privatelink_allowed_principals
  privatelink_acceptance_required = var.privatelink_acceptance_required
  privatelink_source_cidrs        = [local.effective_vpc_cidr]
  bootstrap_health_check_path     = "/api/health"
  target_groups = {
    control-plane = {
      port              = 8080
      protocol          = "HTTP"
      target_type       = "ip"
      health_check_path = "/api/health"
    }
    media-gateway = {
      port              = 8443
      protocol          = "HTTP"
      target_type       = "ip"
      health_check_path = "/healthz"
    }
  }
  tags = local.tags
}

module "redis" {
  source = "../../../../modules/redis"

  name                       = "${local.name_prefix}-redis"
  vpc_id                     = local.effective_vpc_id
  vpc_cidr                   = local.effective_vpc_cidr
  subnet_ids                 = local.effective_data_subnet_ids
  allowed_security_group_ids = [module.ingress.service_security_group_id]
  allowed_cidr_blocks        = [local.effective_vpc_cidr]
  node_type                  = var.redis_node_type
  node_count                 = var.redis_node_count
  engine_version             = var.redis_engine_version
  tags                       = local.tags
}

module "turn" {
  source = "../../../../modules/turn"

  name                              = "${local.name_prefix}-turn"
  vpc_id                            = local.effective_vpc_id
  vpc_cidr                          = local.effective_vpc_cidr
  public_subnet_ids                 = local.effective_public_subnet_ids
  internal_nlb_enabled              = var.turn_internal_nlb_enabled
  internal_subnet_ids               = local.effective_private_subnet_ids
  allowed_client_cidrs              = var.turn_client_cidrs
  ami_id                            = var.turn_ami_id
  instance_type                     = var.turn_instance_type
  min_size                          = var.turn_min_size
  desired_capacity                  = var.turn_desired_capacity
  max_size                          = var.turn_max_size
  realm                             = local.turn_host
  shared_secret_secret_id           = local.turn_shared_secret_id
  shared_secret_secret_arn          = local.turn_shared_secret_arn
  nlb_subnet_mapping_allocation_ids = var.turn_nlb_eip_allocation_ids
  tags                              = local.tags
}

resource "aws_route53_record" "turn_alias" {
  count = local.turn_alias_enabled ? 1 : 0

  allow_overwrite = true
  zone_id         = local.turn_alias_hosted_zone_id
  name            = var.turn_hostname
  type            = "A"

  alias {
    name                   = module.turn.nlb_dns_name
    zone_id                = module.turn.nlb_zone_id
    evaluate_target_health = var.dns_alias_evaluate_target_health
  }
}

resource "aws_route53_zone" "worker_turn_private" {
  count = local.worker_turn_private_dns_zone_enabled ? 1 : 0

  name = local.worker_turn_private_dns_zone_name

  vpc {
    vpc_id = local.effective_vpc_id
  }

  tags = merge(local.tags, {
    Name = local.worker_turn_private_dns_zone_name
  })
}

resource "aws_route53_record" "worker_turn_alias" {
  count = local.worker_turn_alias_enabled ? 1 : 0

  allow_overwrite = true
  zone_id         = local.worker_turn_private_dns_zone_id
  name            = var.worker_turn_hostname
  type            = "A"

  alias {
    name                   = module.turn.internal_nlb_dns_name
    zone_id                = module.turn.internal_nlb_zone_id
    evaluate_target_health = var.dns_alias_evaluate_target_health
  }
}
