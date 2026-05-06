locals {
  root_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Stack       = "standalone-rbi-eks"
    },
    var.tags,
  )

  standard_node_subnet_ids = length(var.standard_node_subnet_ids) > 0 ? var.standard_node_subnet_ids : var.cluster_subnet_ids
  kata_node_subnet_ids     = length(var.kata_node_subnet_ids) > 0 ? var.kata_node_subnet_ids : local.standard_node_subnet_ids
}

module "eks" {
  source = "../../../../modules/eks"

  project_name               = var.project_name
  cluster_name               = var.cluster_name
  cluster_version            = var.cluster_version
  cluster_subnet_ids         = var.cluster_subnet_ids
  standard_node_subnet_ids   = local.standard_node_subnet_ids
  cluster_security_group_ids = var.cluster_security_group_ids
  endpoint_private_access    = var.endpoint_private_access
  endpoint_public_access     = var.endpoint_public_access
  public_access_cidrs        = var.public_access_cidrs
  enabled_cluster_log_types  = var.enabled_cluster_log_types
  cluster_encryption_key_arn = var.cluster_encryption_key_arn

  standard_node_group = {
    name            = "rbi-control"
    instance_types  = var.standard_node_instance_types
    capacity_type   = "ON_DEMAND"
    ami_type        = "AL2023_x86_64_STANDARD"
    min_size        = var.standard_node_min_size
    desired_size    = var.standard_node_desired_size
    max_size        = var.standard_node_max_size
    disk_size       = 40
    labels          = {}
    taints          = []
    max_unavailable = 1
  }

  tags = local.root_tags
}

module "kata_nodegroup" {
  source = "../../../../modules/kata-nodegroup"

  project_name                       = var.project_name
  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  service_ipv4_cidr                  = module.eks.service_ipv4_cidr
  subnet_ids                         = local.kata_node_subnet_ids
  ami_id                             = var.kata_worker_ami_id
  instance_type                      = var.kata_worker_instance_type
  instance_types                     = var.kata_worker_instance_types
  capacity_type                      = var.kata_worker_capacity_type
  desired_size                       = var.kata_node_desired_size
  min_size                           = var.kata_node_min_size
  max_size                           = var.kata_node_max_size
  security_group_ids                 = var.kata_security_group_ids

  tags = local.root_tags

  depends_on = [module.eks]
}
