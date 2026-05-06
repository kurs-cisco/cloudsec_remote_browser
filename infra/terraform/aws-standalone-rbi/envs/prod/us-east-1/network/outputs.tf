output "vpc_id" {
  description = "RBI regional VPC ID."
  value       = local.effective_vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = local.effective_public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private workload subnet IDs."
  value       = local.effective_private_subnet_ids
}

output "data_subnet_ids" {
  description = "Private data subnet IDs."
  value       = local.effective_data_subnet_ids
}

output "ingress_alb_dns_name" {
  description = "Viewer/control-plane ALB DNS name."
  value       = module.ingress.alb_dns_name
}

output "ingress_alb_zone_id" {
  description = "Viewer/control-plane ALB hosted zone ID."
  value       = module.ingress.alb_zone_id
}

output "public_endpoint_alias_fqdn" {
  description = "Route53 alias FQDN for the public RBI hostname, when configured."
  value       = module.ingress.public_alias_fqdn
}

output "ingress_target_group_arns" {
  description = "ALB target group ARNs for future service attachments."
  value       = module.ingress.target_group_arns
}

output "bootstrap_private_dns" {
  description = "Private DNS name for SWG bootstrap consumers when endpoint-service private DNS is configured."
  value       = module.ingress.privatelink_private_dns_name
}

output "privatelink_service_name" {
  description = "PrivateLink endpoint service name for SWG to create an interface endpoint."
  value       = module.ingress.privatelink_service_name
}

output "privatelink_service_id" {
  description = "PrivateLink endpoint service ID."
  value       = module.ingress.privatelink_service_id
}

output "privatelink_bootstrap_target_group_arn" {
  description = "Target group ARN for RBI bootstrap service attachment behind the PrivateLink NLB."
  value       = module.ingress.bootstrap_target_group_arn
}

output "public_handoff_url" {
  description = "Public browser handoff URL used after SWG receives an opaque handoff token."
  value       = "https://${local.public_endpoint_host}/swg/handoff"
}

output "viewer_gateway_url" {
  description = "Public browser viewer gateway base URL."
  value       = "https://${local.public_endpoint_host}"
}

output "workload_security_group_id" {
  description = "Security group intended for future regional RBI workloads."
  value       = module.ingress.service_security_group_id
}

output "redis_primary_endpoint_address" {
  description = "Redis primary endpoint address."
  value       = module.redis.primary_endpoint_address
}

output "redis_reader_endpoint_address" {
  description = "Redis reader endpoint address."
  value       = module.redis.reader_endpoint_address
}

output "redis_security_group_id" {
  description = "Redis security group ID."
  value       = module.redis.security_group_id
}

output "turn_nlb_dns_name" {
  description = "TURN NLB DNS name."
  value       = module.turn.nlb_dns_name
}

output "turn_internal_nlb_dns_name" {
  description = "Internal worker-facing TURN NLB DNS name."
  value       = module.turn.internal_nlb_dns_name
}

output "turn_uris" {
  description = "TURN/STUN URIs advertised to viewers and workers."
  value = [
    "stun:${local.turn_host}:3478",
    "turn:${local.turn_host}:3478?transport=udp",
    "turn:${local.turn_host}:3478?transport=tcp",
    "turn:${local.turn_host}:443?transport=tcp",
  ]
}

output "worker_turn_hostname" {
  description = "Stable worker-facing TURN hostname or internal NLB DNS name."
  value       = local.worker_turn_host
}

output "worker_turn_uris" {
  description = "Worker-facing TURN URIs."
  value = [
    "turn:${local.worker_turn_host}:3478?transport=udp",
    "turn:${local.worker_turn_host}:3478?transport=tcp",
  ]
}

output "turn_nlb_zone_id" {
  description = "TURN NLB hosted zone ID."
  value       = module.turn.nlb_zone_id
}

output "turn_internal_nlb_zone_id" {
  description = "Internal worker-facing TURN NLB hosted zone ID."
  value       = module.turn.internal_nlb_zone_id
}

output "turn_alias_fqdn" {
  description = "Route53 alias FQDN for the TURN hostname, when configured."
  value       = try(aws_route53_record.turn_alias[0].fqdn, null)
}

output "worker_turn_alias_fqdn" {
  description = "Private Route53 alias FQDN for worker-facing TURN, when configured."
  value       = try(aws_route53_record.worker_turn_alias[0].fqdn, null)
}

output "worker_turn_private_dns_zone_id" {
  description = "Private Route53 hosted zone ID used for the worker-facing TURN alias, when configured."
  value       = local.worker_turn_private_dns_zone_id
}

output "turn_security_group_id" {
  description = "TURN instance security group ID."
  value       = module.turn.security_group_id
}
