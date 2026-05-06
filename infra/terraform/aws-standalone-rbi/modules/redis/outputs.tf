output "replication_group_id" {
  description = "Redis replication group ID."
  value       = aws_elasticache_replication_group.this.id
}

output "primary_endpoint_address" {
  description = "Redis primary endpoint address."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint_address" {
  description = "Redis reader endpoint address."
  value       = aws_elasticache_replication_group.this.reader_endpoint_address
}

output "port" {
  description = "Redis port."
  value       = aws_elasticache_replication_group.this.port
}

output "security_group_id" {
  description = "Redis security group ID."
  value       = aws_security_group.this.id
}
