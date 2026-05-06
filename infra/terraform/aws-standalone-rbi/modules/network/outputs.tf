output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = values(aws_subnet.public)[*].id
}

output "private_subnet_ids" {
  description = "Private workload subnet IDs."
  value       = values(aws_subnet.private)[*].id
}

output "data_subnet_ids" {
  description = "Private data subnet IDs."
  value       = values(aws_subnet.data)[*].id
}

output "public_route_table_id" {
  description = "Public route table ID."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "Private workload route table IDs."
  value       = values(aws_route_table.private)[*].id
}

output "data_route_table_ids" {
  description = "Private data route table IDs."
  value       = values(aws_route_table.data)[*].id
}

output "interface_endpoint_security_group_id" {
  description = "Security group ID used by interface VPC endpoints."
  value       = length(aws_security_group.interface_endpoints) > 0 ? aws_security_group.interface_endpoints[0].id : null
}
