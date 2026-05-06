resource "aws_security_group" "this" {
  name        = var.name
  description = "Redis access for RBI regional services"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = toset(var.allowed_security_group_ids)

    content {
      description     = "Redis from approved RBI service security group"
      from_port       = var.port
      to_port         = var.port
      protocol        = "tcp"
      security_groups = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = toset(var.allowed_cidr_blocks)

    content {
      description = "Redis from approved RBI workload CIDR"
      from_port   = var.port
      to_port     = var.port
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "Redis egress inside the RBI VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.tags, {
    Name = var.name
  })
}

resource "aws_elasticache_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids

  tags = merge(local.tags, {
    Name = var.name
  })
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.name
  description          = "Redis session and signaling state for ${var.name}"

  engine         = "redis"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = var.port

  parameter_group_name = var.parameter_group_name
  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.this.id]

  num_cache_clusters         = var.node_count
  automatic_failover_enabled = var.node_count > 1
  multi_az_enabled           = var.node_count > 1

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  kms_key_id                 = var.kms_key_id
  user_group_ids             = var.user_group_ids

  snapshot_retention_limit   = var.snapshot_retention_limit
  maintenance_window         = var.maintenance_window
  apply_immediately          = var.apply_immediately
  auto_minor_version_upgrade = true

  tags = merge(local.tags, {
    Name = var.name
  })
}
