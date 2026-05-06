locals {
  tags = merge(
    var.tags,
    {
      Module = "redis"
    }
  )
}
