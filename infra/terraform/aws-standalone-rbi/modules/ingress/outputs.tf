output "alb_arn" {
  description = "ALB ARN."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID."
  value       = aws_lb.this.zone_id
}

output "public_alias_fqdn" {
  description = "Route53 alias FQDN for the RBI public hostname, when configured."
  value       = try(aws_route53_record.public_alias[0].fqdn, null)
}

output "alb_security_group_id" {
  description = "ALB security group ID."
  value       = aws_security_group.alb.id
}

output "service_security_group_id" {
  description = "Security group intended for future RBI services behind the ALB."
  value       = aws_security_group.service.id
}

output "target_group_arns" {
  description = "Target group ARNs keyed by logical name."
  value = {
    for key, target_group in aws_lb_target_group.this : key => target_group.arn
  }
}

output "bootstrap_nlb_dns_name" {
  description = "Private NLB DNS name for SWG bootstrap traffic."
  value       = try(aws_lb.bootstrap[0].dns_name, null)
}

output "bootstrap_target_group_arn" {
  description = "PrivateLink bootstrap target group ARN."
  value       = try(aws_lb_target_group.bootstrap[0].arn, null)
}

output "privatelink_service_name" {
  description = "AWS PrivateLink endpoint service name SWG consumers use to create an interface endpoint."
  value       = try(aws_vpc_endpoint_service.bootstrap[0].service_name, null)
}

output "privatelink_service_id" {
  description = "AWS PrivateLink endpoint service ID."
  value       = try(aws_vpc_endpoint_service.bootstrap[0].id, null)
}

output "privatelink_private_dns_name" {
  description = "Private DNS name configured for the endpoint service, if supplied."
  value       = try(aws_vpc_endpoint_service.bootstrap[0].private_dns_name, null)
}

output "privatelink_private_dns_verification_record_fqdn" {
  description = "Route53 TXT record FQDN used to verify PrivateLink private DNS ownership."
  value       = try(aws_route53_record.privatelink_private_dns_verification[0].fqdn, null)
}
