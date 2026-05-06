resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name                 = "${var.name_prefix}-${each.key}"
  image_tag_mutability = each.value.image_tag_mutability
  force_delete         = each.value.force_delete

  image_scanning_configuration {
    scan_on_push = each.value.scan_on_push
  }

  encryption_configuration {
    encryption_type = each.value.encryption_type
    kms_key         = each.value.kms_key_arn
  }

  tags = merge(local.tags, {
    Name = "${var.name_prefix}-${each.key}"
  })
}

resource "aws_ecr_lifecycle_policy" "count_limit" {
  for_each = {
    for key, repo in var.repositories : key => repo
    if repo.max_image_count != null
  }

  repository = aws_ecr_repository.this[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the most recent ${each.value.max_image_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = each.value.max_image_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
