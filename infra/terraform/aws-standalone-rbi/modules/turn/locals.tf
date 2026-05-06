locals {
  image_id = coalesce(var.ami_id, one(data.aws_ami.al2023[*].id))
  tcp_listener_client_cidrs = [
    for cidr in var.allowed_client_cidrs : cidr
    if cidr != var.vpc_cidr
  ]

  nlb_subnet_mappings = length(var.nlb_subnet_mapping_allocation_ids) == 0 ? {} : zipmap(
    var.public_subnet_ids,
    var.nlb_subnet_mapping_allocation_ids
  )

  nlb_name = substr(var.name, 0, 32)
  internal_nlb_name = substr(
    "${substr(var.name, 0, 27)}-int",
    0,
    32
  )
  internal_subnet_ids = length(var.internal_subnet_ids) > 0 ? var.internal_subnet_ids : var.public_subnet_ids
  tg_name_base        = substr(var.name, 0, 24)
  udp_tg_name         = substr("${local.tg_name_base}-relay", 0, 32)
  tcp_tg_name         = substr("${local.tg_name_base}-tcp", 0, 32)
  tls_tg_name         = substr("${local.tg_name_base}-tls", 0, 32)

  tags = merge(
    var.tags,
    {
      Module = "turn"
    }
  )
}
