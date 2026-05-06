locals {
  common_tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "terraform"
    },
    var.tags,
  )

  node_role_name = var.node_role_name != "" ? var.node_role_name : "${var.cluster_name}-${var.node_group_name}"
  node_role_arn  = var.create_node_role ? aws_iam_role.kata_nodes[0].arn : var.node_role_arn
  instance_types = length(var.instance_types) > 0 ? var.instance_types : [var.instance_type]

  taint_effect_to_kubelet = {
    NO_EXECUTE         = "NoExecute"
    NO_SCHEDULE        = "NoSchedule"
    PREFER_NO_SCHEDULE = "PreferNoSchedule"
  }

  node_labels_csv = join(",", [
    for key, value in var.node_labels : "${key}=${value}"
  ])

  node_taints_csv = join(",", [
    for taint in var.node_taints : "${taint.key}${try(taint.value, null) == null ? "" : "=${taint.value}"}:${lookup(local.taint_effect_to_kubelet, taint.effect, taint.effect)}"
  ])

  user_data = templatefile("${path.module}/templates/al2023-kata-worker-user-data.mime.tftpl", {
    cluster_name                       = var.cluster_name
    cluster_endpoint                   = var.cluster_endpoint
    cluster_certificate_authority_data = var.cluster_certificate_authority_data
    service_ipv4_cidr                  = var.service_ipv4_cidr
    node_labels_csv                    = local.node_labels_csv
    node_taints_csv                    = local.node_taints_csv
    runtime_class_name                 = var.runtime_class_name
    expected_runtime_types             = join(" ", var.expected_runtime_types)
    host_bootstrap_script_path         = var.host_bootstrap_script_path
  })
}

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "kata_nodes" {
  count = var.create_node_role ? 1 : 0

  name               = local.node_role_name
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = merge(local.common_tags, {
    Name                                        = local.node_role_name
    "cloudsec.cisco.com/rbi-plane"              = "worker"
    "cloudsec.cisco.com/node-pool"              = "rbi-workers"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

resource "aws_iam_role_policy_attachment" "kata_nodes" {
  for_each = var.create_node_role ? toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]) : toset([])

  role       = aws_iam_role.kata_nodes[0].name
  policy_arn = each.value
}

resource "aws_launch_template" "kata" {
  name_prefix            = "${var.cluster_name}-${var.node_group_name}-"
  description            = "AL2023 Kata launch template for ${var.cluster_name}/${var.node_group_name}"
  image_id               = var.ami_id
  instance_type          = length(var.instance_types) > 0 ? null : var.instance_type
  update_default_version = true
  user_data              = base64encode(local.user_data)
  vpc_security_group_ids = length(var.security_group_ids) > 0 ? var.security_group_ids : null

  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = var.root_device_name

    ebs {
      delete_on_termination = true
      encrypted             = true
      volume_size           = var.root_volume_size_gib
      volume_type           = "gp3"
      iops                  = var.root_volume_iops
      throughput            = var.root_volume_throughput
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(local.common_tags, {
      Name                           = "${var.cluster_name}-${var.node_group_name}"
      "cloudsec.cisco.com/rbi-plane" = "worker"
      "cloudsec.cisco.com/node-pool" = "rbi-workers"
      "cloudsec.cisco.com/cluster"   = var.cluster_name
    })
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(local.common_tags, {
      Name                           = "${var.cluster_name}-${var.node_group_name}"
      "cloudsec.cisco.com/rbi-plane" = "worker"
      "cloudsec.cisco.com/node-pool" = "rbi-workers"
      "cloudsec.cisco.com/cluster"   = var.cluster_name
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "kata" {
  cluster_name         = var.cluster_name
  node_group_name      = var.node_group_name
  node_role_arn        = local.node_role_arn
  subnet_ids           = var.subnet_ids
  capacity_type        = var.capacity_type
  force_update_version = var.force_update_version
  instance_types       = local.instance_types
  labels               = var.node_labels

  launch_template {
    id      = aws_launch_template.kata.id
    version = aws_launch_template.kata.latest_version
  }

  scaling_config {
    desired_size = var.desired_size
    max_size     = var.max_size
    min_size     = var.min_size
  }

  update_config {
    max_unavailable = var.max_unavailable
  }

  dynamic "taint" {
    for_each = var.node_taints

    content {
      key    = taint.value.key
      value  = try(taint.value.value, null)
      effect = taint.value.effect
    }
  }

  tags = merge(local.common_tags, {
    Name                           = "${var.cluster_name}-${var.node_group_name}"
    "cloudsec.cisco.com/rbi-plane" = "worker"
    "cloudsec.cisco.com/node-pool" = "rbi-workers"
  })

  depends_on = [aws_iam_role_policy_attachment.kata_nodes]
}
