module "ecr" {
  source = "../../../modules/ecr"

  name_prefix  = local.name_prefix
  repositories = var.ecr_repositories
  tags         = local.tags
}
