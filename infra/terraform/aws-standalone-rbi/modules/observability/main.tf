locals {
  event_targets = {
    for target in flatten([
      for rule_key, rule in var.event_rules : [
        for target_index, target_arn in(rule.target_arns != null ? rule.target_arns : []) : {
          key        = "${rule_key}-${target_index}"
          rule_key   = rule_key
          target_arn = target_arn
        }
      ]
    ]) : target.key => target
  }
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = var.log_groups

  name              = each.value.name != null ? each.value.name : each.key
  retention_in_days = each.value.retention_in_days != null ? each.value.retention_in_days : 90
  kms_key_id        = each.value.kms_key_id
  skip_destroy      = coalesce(each.value.skip_destroy, false)

  tags = merge(
    var.tags,
    each.value.tags != null ? each.value.tags : {},
    {
      Module = "observability"
    }
  )
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each = var.event_rules

  name          = each.value.name != null ? each.value.name : each.key
  description   = each.value.description
  event_pattern = each.value.event_pattern
  state         = each.value.state != null ? each.value.state : "ENABLED"

  tags = merge(
    var.tags,
    each.value.tags != null ? each.value.tags : {},
    {
      Module = "observability"
    }
  )
}

resource "aws_cloudwatch_event_target" "this" {
  for_each = local.event_targets

  rule      = aws_cloudwatch_event_rule.this[each.value.rule_key].name
  target_id = substr(replace(each.key, "/[^A-Za-z0-9_-]/", "-"), 0, 64)
  arn       = each.value.target_arn
}
