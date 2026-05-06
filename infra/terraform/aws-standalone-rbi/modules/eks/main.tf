locals {
  common_tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "terraform"
    },
    var.tags,
  )

  cluster_role_name       = "${var.cluster_name}-eks-cluster"
  standard_node_role_name = var.standard_node_role_name != "" ? var.standard_node_role_name : "${var.cluster_name}-standard-nodes"

  standard_node_labels = merge(
    {
      "cloudsec.cisco.com/rbi-plane" = "control"
      "cloudsec.cisco.com/node-pool" = "control-plane"
    },
    var.standard_node_group.labels,
  )
}

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = local.cluster_role_name
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json

  tags = merge(local.common_tags, {
    Name = local.cluster_role_name
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

resource "aws_eks_cluster" "this" {
  name                      = var.cluster_name
  role_arn                  = aws_iam_role.cluster.arn
  version                   = var.cluster_version
  enabled_cluster_log_types = var.enabled_cluster_log_types

  access_config {
    authentication_mode                         = var.authentication_mode
    bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin_permissions
  }

  vpc_config {
    subnet_ids              = var.cluster_subnet_ids
    security_group_ids      = var.cluster_security_group_ids
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.public_access_cidrs
  }

  kubernetes_network_config {
    ip_family         = var.ip_family
    service_ipv4_cidr = var.service_ipv4_cidr
  }

  dynamic "encryption_config" {
    for_each = var.cluster_encryption_key_arn == "" ? [] : [var.cluster_encryption_key_arn]

    content {
      provider {
        key_arn = encryption_config.value
      }
      resources = ["secrets"]
    }
  }

  tags = merge(local.common_tags, {
    Name = var.cluster_name
  })

  lifecycle {
    precondition {
      condition     = !var.endpoint_public_access || length(var.public_access_cidrs) > 0
      error_message = "public_access_cidrs must be explicitly set when endpoint_public_access is true."
    }
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_eks_addon" "default" {
  for_each = var.cluster_addons

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = try(each.value.addon_version, null)
  configuration_values        = try(each.value.configuration_values, null)
  service_account_role_arn    = try(each.value.service_account_role_arn, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-${each.key}"
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

resource "aws_iam_role" "standard_nodes" {
  name               = local.standard_node_role_name
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = merge(local.common_tags, {
    Name                                        = local.standard_node_role_name
    "cloudsec.cisco.com/rbi-plane"              = "control"
    "cloudsec.cisco.com/node-pool"              = "control-plane"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

resource "aws_iam_role_policy_attachment" "standard_nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.standard_nodes.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "standard" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = var.standard_node_group.name
  node_role_arn   = aws_iam_role.standard_nodes.arn
  subnet_ids      = var.standard_node_subnet_ids

  ami_type       = var.standard_node_group.ami_type
  capacity_type  = var.standard_node_group.capacity_type
  disk_size      = var.standard_node_group.disk_size
  instance_types = var.standard_node_group.instance_types
  labels         = local.standard_node_labels
  version        = var.cluster_version

  scaling_config {
    desired_size = var.standard_node_group.desired_size
    max_size     = var.standard_node_group.max_size
    min_size     = var.standard_node_group.min_size
  }

  update_config {
    max_unavailable = var.standard_node_group.max_unavailable
  }

  dynamic "taint" {
    for_each = var.standard_node_group.taints

    content {
      key    = taint.value.key
      value  = try(taint.value.value, null)
      effect = taint.value.effect
    }
  }

  tags = merge(local.common_tags, {
    Name                           = "${var.cluster_name}-${var.standard_node_group.name}"
    "cloudsec.cisco.com/rbi-plane" = "control"
    "cloudsec.cisco.com/node-pool" = "control-plane"
  })

  depends_on = [aws_iam_role_policy_attachment.standard_nodes]
}
