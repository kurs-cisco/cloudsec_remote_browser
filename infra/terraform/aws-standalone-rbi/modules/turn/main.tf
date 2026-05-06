data "aws_ami" "al2023" {
  count = var.ami_id == null || var.ami_id == "" ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_region" "current" {}

resource "aws_security_group" "this" {
  name        = var.name
  description = "TURN listener and relay access"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = length(var.allowed_client_cidrs) > 0 ? [1] : []

    content {
      description = "TURN UDP listener"
      from_port   = var.turn_port
      to_port     = var.turn_port
      protocol    = "udp"
      cidr_blocks = var.allowed_client_cidrs
    }
  }

  ingress {
    description = "TURN NLB health checks from inside the VPC"
    from_port   = var.turn_port
    to_port     = var.turn_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  dynamic "ingress" {
    for_each = length(local.tcp_listener_client_cidrs) > 0 ? [1] : []

    content {
      description = "TURN TCP listener"
      from_port   = var.turn_port
      to_port     = var.turn_port
      protocol    = "tcp"
      cidr_blocks = local.tcp_listener_client_cidrs
    }
  }

  dynamic "ingress" {
    for_each = length(var.allowed_client_cidrs) > 0 ? [1] : []

    content {
      description = "TURN TLS listener"
      from_port   = var.tls_port
      to_port     = var.tls_port
      protocol    = "tcp"
      cidr_blocks = var.allowed_client_cidrs
    }
  }

  dynamic "ingress" {
    for_each = length(var.allowed_client_cidrs) > 0 ? [1] : []

    content {
      description = "TURN UDP relay ports"
      from_port   = var.relay_port_min
      to_port     = var.relay_port_max
      protocol    = "udp"
      cidr_blocks = var.allowed_client_cidrs
    }
  }

  egress {
    description = "TURN egress to approved clients and internal RBI endpoints"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = distinct(concat([var.vpc_cidr], var.allowed_client_cidrs))
  }

  dynamic "egress" {
    for_each = length(var.bootstrap_https_egress_cidrs) > 0 ? [1] : []

    content {
      description = "TURN bootstrap HTTPS egress to package repositories and image registries"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = var.bootstrap_https_egress_cidrs
    }
  }

  tags = merge(local.tags, {
    Name = var.name
  })
}

resource "aws_iam_role" "this" {
  name = "${var.name}-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.tags, {
    Name = "${var.name}-instance"
  })
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "additional" {
  for_each = toset(var.additional_instance_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.key
}

data "aws_iam_policy_document" "secret_read" {
  count = var.shared_secret_secret_arn != "" ? 1 : 0

  statement {
    sid    = "AllowTurnSharedSecretRead"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = [var.shared_secret_secret_arn]
  }

  statement {
    sid    = "AllowTurnSharedSecretKmsDecrypt"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "secret_read" {
  count = var.shared_secret_secret_arn != "" ? 1 : 0

  name   = "turn-shared-secret-read"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.secret_read[0].json
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-instance"
  role = aws_iam_role.this.name

  tags = merge(local.tags, {
    Name = "${var.name}-instance"
  })
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-"
  image_id      = local.image_id
  instance_type = var.instance_type
  key_name      = var.key_name
  user_data = base64encode(templatefile("${path.module}/templates/turn-user-data.sh.tftpl", {
    realm                   = var.realm
    shared_secret_secret_id = var.shared_secret_secret_id
    shared_secret_json_key  = var.shared_secret_json_key
    coturn_image            = var.coturn_image
    turn_port               = var.turn_port
    tls_port                = var.tls_port
    relay_port_min          = var.relay_port_min
    relay_port_max          = var.relay_port_max
    start_coturn_script_b64 = filebase64("${path.module}/../../images/turn/scripts/start-coturn.sh")
    turn_service_b64        = filebase64("${path.module}/../../images/turn/files/cloudsec-rbi-turn.service")
  }))

  vpc_security_group_ids = [aws_security_group.this.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(local.tags, {
      Name = var.name
    })
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(local.tags, {
      Name = var.name
    })
  }

  tags = merge(local.tags, {
    Name = var.name
  })
}

resource "aws_lb" "this" {
  name               = local.nlb_name
  internal           = var.nlb_internal
  load_balancer_type = "network"
  subnets            = length(local.nlb_subnet_mappings) == 0 ? var.public_subnet_ids : null

  dynamic "subnet_mapping" {
    for_each = local.nlb_subnet_mappings

    content {
      subnet_id     = subnet_mapping.key
      allocation_id = subnet_mapping.value
    }
  }

  enable_deletion_protection = true

  tags = merge(local.tags, {
    Name = var.name
  })
}

resource "aws_lb" "internal" {
  count = var.internal_nlb_enabled ? 1 : 0

  name               = local.internal_nlb_name
  internal           = true
  load_balancer_type = "network"
  subnets            = local.internal_subnet_ids

  enable_deletion_protection = true

  tags = merge(local.tags, {
    Name = "${var.name}-internal"
  })
}

resource "aws_lb_target_group" "turn_udp" {
  name        = local.udp_tg_name
  port        = var.turn_port
  protocol    = "TCP_UDP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = tostring(var.turn_port)
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = merge(local.tags, {
    Name = "${var.name}-tcp-udp"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "turn_udp_internal" {
  count = var.internal_nlb_enabled ? 1 : 0

  name_prefix = "rbiui"
  port        = var.turn_port
  protocol    = "TCP_UDP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = tostring(var.turn_port)
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = merge(local.tags, {
    Name = "${var.name}-internal-tcp-udp"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "turn_tls" {
  name_prefix = "rbitls"
  port        = var.turn_port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = tostring(var.turn_port)
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = merge(local.tags, {
    Name = "${var.name}-tls"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "turn_tls_internal" {
  count = var.internal_nlb_enabled ? 1 : 0

  name_prefix = "rbitli"
  port        = var.turn_port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = tostring(var.turn_port)
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = merge(local.tags, {
    Name = "${var.name}-internal-tls"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "turn_udp" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.turn_port
  protocol          = "TCP_UDP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.turn_udp.arn
  }
}

resource "aws_lb_listener" "turn_udp_internal" {
  count = var.internal_nlb_enabled ? 1 : 0

  load_balancer_arn = aws_lb.internal[0].arn
  port              = var.turn_port
  protocol          = "TCP_UDP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.turn_udp_internal[0].arn
  }
}

resource "aws_lb_listener" "turn_tls" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.tls_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.turn_tls.arn
  }
}

resource "aws_lb_listener" "turn_tls_internal" {
  count = var.internal_nlb_enabled ? 1 : 0

  load_balancer_arn = aws_lb.internal[0].arn
  port              = var.tls_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.turn_tls_internal[0].arn
  }
}

resource "aws_autoscaling_group" "this" {
  name                      = var.name
  min_size                  = var.min_size
  desired_capacity          = var.desired_capacity
  max_size                  = var.max_size
  health_check_type         = "ELB"
  health_check_grace_period = 300
  vpc_zone_identifier       = var.public_subnet_ids
  target_group_arns = concat(
    [
      aws_lb_target_group.turn_udp.arn,
      aws_lb_target_group.turn_tls.arn,
    ],
    var.internal_nlb_enabled ? [
      aws_lb_target_group.turn_udp_internal[0].arn,
      aws_lb_target_group.turn_tls_internal[0].arn,
    ] : []
  )

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  dynamic "tag" {
    for_each = merge(local.tags, {
      Name = var.name
    })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}
