output "autoscaling_group_name" {
  description = "TURN autoscaling group name."
  value       = aws_autoscaling_group.this.name
}

output "launch_template_id" {
  description = "TURN launch template ID."
  value       = aws_launch_template.this.id
}

output "security_group_id" {
  description = "TURN instance security group ID."
  value       = aws_security_group.this.id
}

output "iam_role_name" {
  description = "TURN instance IAM role name."
  value       = aws_iam_role.this.name
}

output "nlb_arn" {
  description = "TURN NLB ARN."
  value       = aws_lb.this.arn
}

output "nlb_dns_name" {
  description = "TURN NLB DNS name."
  value       = aws_lb.this.dns_name
}

output "nlb_zone_id" {
  description = "TURN NLB hosted zone ID."
  value       = aws_lb.this.zone_id
}

output "internal_nlb_dns_name" {
  description = "Internal worker-facing TURN NLB DNS name."
  value       = try(aws_lb.internal[0].dns_name, null)
}

output "internal_nlb_zone_id" {
  description = "Internal worker-facing TURN NLB hosted zone ID."
  value       = try(aws_lb.internal[0].zone_id, null)
}

output "target_group_arns" {
  description = "TURN target group ARNs."
  value = {
    udp          = aws_lb_target_group.turn_udp.arn
    tcp          = aws_lb_target_group.turn_udp.arn
    tls          = aws_lb_target_group.turn_tls.arn
    internal_udp = try(aws_lb_target_group.turn_udp_internal[0].arn, null)
    internal_tcp = try(aws_lb_target_group.turn_udp_internal[0].arn, null)
    internal_tls = try(aws_lb_target_group.turn_tls_internal[0].arn, null)
  }
}
