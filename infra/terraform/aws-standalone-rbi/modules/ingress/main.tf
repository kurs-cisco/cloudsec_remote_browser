resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public ALB access for the RBI control plane and viewer ingress"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = length(var.allowed_ingress_cidrs) > 0 ? [1] : []

    content {
      description = "HTTP from approved client ranges"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = var.allowed_ingress_cidrs
    }
  }

  dynamic "ingress" {
    for_each = local.has_certificate && length(var.allowed_ingress_cidrs) > 0 ? [1] : []

    content {
      description = "HTTPS from approved client ranges"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = var.allowed_ingress_cidrs
    }
  }

  egress {
    description = "ALB egress to RBI service targets in the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.tags, {
    Name = "${var.name}-alb"
  })
}

resource "aws_security_group" "service" {
  name        = "${var.name}-services"
  description = "Future RBI service access from the ALB"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = toset(local.target_group_ports)

    content {
      description     = "ALB to service port ${ingress.value}"
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      security_groups = [aws_security_group.alb.id]
    }
  }

  dynamic "ingress" {
    for_each = length(var.privatelink_source_cidrs) > 0 ? [1] : []

    content {
      description = "PrivateLink bootstrap NLB to RBI service port"
      from_port   = var.bootstrap_port
      to_port     = var.bootstrap_port
      protocol    = "tcp"
      cidr_blocks = var.privatelink_source_cidrs
    }
  }

  egress {
    description = "RBI service egress inside the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.tags, {
    Name = "${var.name}-services"
  })
}

resource "aws_lb" "this" {
  name               = local.alb_name
  internal           = var.internal
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = true
  idle_timeout               = 120

  dynamic "access_logs" {
    for_each = var.alb_access_logs_enabled && var.alb_access_logs_bucket != "" ? [1] : []

    content {
      bucket  = var.alb_access_logs_bucket
      prefix  = var.alb_access_logs_prefix
      enabled = true
    }
  }

  tags = merge(local.tags, {
    Name = "${var.name}-alb"
  })
}

resource "aws_route53_record" "public_alias" {
  count = local.public_alias_enabled ? 1 : 0

  allow_overwrite = true
  zone_id         = var.public_hosted_zone_id
  name            = var.public_hostname
  type            = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = var.dns_alias_evaluate_target_health
  }
}

resource "aws_lb_target_group" "this" {
  for_each = var.target_groups

  name                 = local.target_group_names[each.key]
  port                 = each.value.port
  protocol             = each.value.protocol
  target_type          = each.value.target_type
  vpc_id               = var.vpc_id
  deregistration_delay = each.value.deregistration_delay

  health_check {
    enabled             = true
    path                = each.value.health_check_path
    matcher             = each.value.health_check_matcher
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.tags, {
    Name = "${var.name}-${each.key}"
  })
}

resource "aws_lb_listener" "http_redirect" {
  count = local.has_certificate && var.enable_http_redirect ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "http_fixed_response" {
  count = local.has_certificate && var.enable_http_redirect ? 0 : 1

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.default_forward_enabled ? [1] : []

    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.this[var.default_target_group_key].arn
    }
  }

  dynamic "default_action" {
    for_each = local.default_forward_enabled ? [] : [1]

    content {
      type = "fixed-response"

      fixed_response {
        content_type = "text/plain"
        message_body = "No default RBI target is attached."
        status_code  = "404"
      }
    }
  }
}

resource "aws_lb_listener" "https_fixed_response" {
  count = local.has_certificate ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  dynamic "default_action" {
    for_each = local.default_forward_enabled ? [1] : []

    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.this[var.default_target_group_key].arn
    }
  }

  dynamic "default_action" {
    for_each = local.default_forward_enabled ? [] : [1]

    content {
      type = "fixed-response"

      fixed_response {
        content_type = "text/plain"
        message_body = "No default RBI target is attached."
        status_code  = "404"
      }
    }
  }
}

resource "aws_lb_listener_rule" "https" {
  for_each = local.has_certificate ? local.listener_rules : {}

  listener_arn = aws_lb_listener.https_fixed_response[0].arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.value.target_group_key].arn
  }

  dynamic "condition" {
    for_each = length(each.value.path_patterns) > 0 ? [1] : []

    content {
      path_pattern {
        values = each.value.path_patterns
      }
    }
  }

  dynamic "condition" {
    for_each = length(each.value.host_headers) > 0 ? [1] : []

    content {
      host_header {
        values = each.value.host_headers
      }
    }
  }
}

resource "aws_lb" "bootstrap" {
  count = local.bootstrap_enabled ? 1 : 0

  name               = local.bootstrap_nlb_name
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids

  enable_deletion_protection       = true
  enable_cross_zone_load_balancing = var.bootstrap_nlb_cross_zone_enabled

  tags = merge(local.tags, {
    Name = "${var.name}-bootstrap-nlb"
    Role = "swg-bootstrap-privatelink"
  })
}

resource "aws_lb_target_group" "bootstrap" {
  count = local.bootstrap_enabled ? 1 : 0

  name                 = local.bootstrap_tg_name
  port                 = var.bootstrap_port
  protocol             = "TCP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = var.bootstrap_health_check_path
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.tags, {
    Name = "${var.name}-bootstrap"
    Role = "swg-bootstrap-privatelink"
  })
}

resource "aws_lb_listener" "bootstrap" {
  count = local.bootstrap_enabled ? 1 : 0

  load_balancer_arn = aws_lb.bootstrap[0].arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.bootstrap[0].arn
  }
}

resource "aws_vpc_endpoint_service" "bootstrap" {
  count = local.bootstrap_enabled ? 1 : 0

  acceptance_required        = var.privatelink_acceptance_required
  network_load_balancer_arns = [aws_lb.bootstrap[0].arn]
  private_dns_name           = var.privatelink_private_dns_name

  tags = merge(local.tags, {
    Name = "${var.name}-bootstrap-endpoint-service"
    Role = "swg-bootstrap-privatelink"
  })
}

resource "aws_route53_record" "privatelink_private_dns_verification" {
  count = local.privatelink_private_dns_verification_enabled ? 1 : 0

  allow_overwrite = true
  zone_id         = var.privatelink_private_dns_hosted_zone_id
  name            = local.privatelink_private_dns_verification_name
  type            = try(aws_vpc_endpoint_service.bootstrap[0].private_dns_name_configuration[0].type, "TXT")
  ttl             = 300
  records         = [aws_vpc_endpoint_service.bootstrap[0].private_dns_name_configuration[0].value]
}

resource "aws_vpc_endpoint_service_allowed_principal" "bootstrap" {
  for_each = local.bootstrap_enabled ? toset(var.privatelink_allowed_principals) : toset([])

  vpc_endpoint_service_id = aws_vpc_endpoint_service.bootstrap[0].id
  principal_arn           = each.value
}
