resource "aws_security_group" "endpoint" {
  name        = local.name
  description = "SWG access to standalone RBI PrivateLink bootstrap endpoint"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, {
    Name = local.name
  })
}

resource "aws_security_group_rule" "endpoint_ingress_cidr" {
  for_each = toset(local.endpoint_source_cidrs)

  type              = "ingress"
  security_group_id = aws_security_group.endpoint.id
  description       = "SWG clients to RBI bootstrap PrivateLink endpoint"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [each.value]
}

resource "aws_security_group_rule" "endpoint_ingress_sg" {
  for_each = toset(var.allowed_client_security_group_ids)

  type                     = "ingress"
  security_group_id        = aws_security_group.endpoint.id
  description              = "SWG client SG to RBI bootstrap PrivateLink endpoint"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = each.value
}

resource "aws_security_group_rule" "endpoint_egress" {
  for_each = toset(var.vpc_cidr_blocks)

  type              = "egress"
  security_group_id = aws_security_group.endpoint.id
  description       = "Endpoint responses inside SWG VPC"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [each.value]
}

resource "aws_vpc_endpoint" "rbi_bootstrap" {
  vpc_id              = var.vpc_id
  service_name        = var.endpoint_service_name
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = var.private_dns_enabled
  subnet_ids          = var.subnet_ids
  security_group_ids  = concat([aws_security_group.endpoint.id], var.additional_endpoint_security_group_ids)

  tags = merge(local.tags, {
    Name = local.name
    Role = "swg-rbi-bootstrap-consumer"
  })
}
