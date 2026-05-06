output "vpc_endpoint_id" {
  description = "SWG consumer interface endpoint ID. Provider account must accept this when acceptance_required is true."
  value       = aws_vpc_endpoint.rbi_bootstrap.id
}

output "vpc_endpoint_state" {
  description = "Current interface endpoint state."
  value       = aws_vpc_endpoint.rbi_bootstrap.state
}

output "endpoint_security_group_id" {
  description = "Security group attached to the RBI bootstrap interface endpoint."
  value       = aws_security_group.endpoint.id
}

output "dns_entry" {
  description = "Endpoint DNS entries. The provider private DNS name resolves only inside this VPC when private_dns_enabled is true and the endpoint is accepted."
  value       = aws_vpc_endpoint.rbi_bootstrap.dns_entry
}

output "bootstrap_private_dns_enabled" {
  description = "Whether provider private DNS is enabled on the consumer endpoint."
  value       = aws_vpc_endpoint.rbi_bootstrap.private_dns_enabled
}
