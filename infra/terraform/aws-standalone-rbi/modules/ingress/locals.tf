locals {
  has_certificate      = var.certificate_arn != null && var.certificate_arn != ""
  public_alias_enabled = var.public_hostname != "" && var.public_hosted_zone_id != ""
  target_group_ports   = distinct([for target_group in values(var.target_groups) : target_group.port])
  default_forward_enabled = (
    var.default_target_group_key != "" &&
    contains(keys(var.target_groups), var.default_target_group_key)
  )
  listener_rules = {
    for rule_key, rule in var.listener_rules : rule_key => rule
    if contains(keys(var.target_groups), rule.target_group_key)
  }
  alb_name           = substr("${var.name}-alb", 0, 32)
  bootstrap_enabled  = var.enable_privatelink_bootstrap && length(var.private_subnet_ids) > 0
  bootstrap_nlb_name = substr("${var.name}-bootstrap", 0, 32)
  bootstrap_tg_name  = substr("${var.name}-bootstrap", 0, 32)
  privatelink_private_dns_verification_enabled = (
    local.bootstrap_enabled &&
    var.privatelink_private_dns_name != "" &&
    var.privatelink_private_dns_hosted_zone_id != ""
  )
  privatelink_private_dns_verification_raw_name = try(aws_vpc_endpoint_service.bootstrap[0].private_dns_name_configuration[0].name, "")
  privatelink_private_dns_verification_name = (
    local.privatelink_private_dns_verification_raw_name == "" ? "" :
    can(regex("\\.", local.privatelink_private_dns_verification_raw_name)) ?
    local.privatelink_private_dns_verification_raw_name :
    "${local.privatelink_private_dns_verification_raw_name}.${var.privatelink_private_dns_name}"
  )

  target_group_names = {
    for key in keys(var.target_groups) : key => substr(
      "${substr(var.name, 0, 20)}-${substr(replace(key, "_", "-"), 0, 6)}-${substr(sha1(key), 0, 4)}",
      0,
      32
    )
  }

  tags = merge(
    var.tags,
    {
      Module = "ingress"
    }
  )
}
