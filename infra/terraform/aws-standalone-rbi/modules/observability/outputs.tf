output "log_group_names" {
  description = "CloudWatch log group names by key."
  value       = { for log_key, log_group in aws_cloudwatch_log_group.this : log_key => log_group.name }
}

output "event_rule_arns" {
  description = "EventBridge rule ARNs by key."
  value       = { for rule_key, rule in aws_cloudwatch_event_rule.this : rule_key => rule.arn }
}

output "event_target_ids" {
  description = "EventBridge target IDs by key."
  value       = { for target_key, target in aws_cloudwatch_event_target.this : target_key => target.target_id }
}
