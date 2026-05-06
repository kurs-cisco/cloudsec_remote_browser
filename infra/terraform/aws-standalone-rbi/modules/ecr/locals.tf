locals {
  tags = merge(
    var.tags,
    {
      Module = "ecr"
    }
  )
}
