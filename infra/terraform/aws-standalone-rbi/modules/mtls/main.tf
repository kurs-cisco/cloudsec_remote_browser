locals {
  validation_records = {
    for item in flatten([
      for certificate_key, certificate in aws_acm_certificate.public : [
        for domain_validation_option in certificate.domain_validation_options : {
          key             = "${certificate_key}:${domain_validation_option.domain_name}"
          certificate_key = certificate_key
          hosted_zone_id  = var.public_certificates[certificate_key].hosted_zone_id
          name            = domain_validation_option.resource_record_name
          type            = domain_validation_option.resource_record_type
          record          = domain_validation_option.resource_record_value
        }
        if coalesce(var.public_certificates[certificate_key].create_route53_records, false) && var.public_certificates[certificate_key].hosted_zone_id != null
      ]
    ]) : item.key => item
  }

  trust_bundle_parameter_prefix = trimsuffix(var.trust_bundle_parameter_prefix, "/")

  trust_bundle_metadata = {
    for bundle_key, bundle in var.trust_bundles :
    bundle_key => {
      description = bundle.description
      ca_arn      = bundle.ca_arn != null ? bundle.ca_arn : try(aws_acmpca_certificate_authority.private[bundle.pca_key].arn, null)
      pca_key     = bundle.pca_key
      s3_uri      = bundle.s3_uri
      version     = bundle.version
      value_type  = "trust-bundle-metadata"
      secret      = false
    }
  }
}

resource "aws_acm_certificate" "public" {
  for_each = var.public_certificates

  domain_name               = each.value.domain_name
  subject_alternative_names = each.value.subject_alternative_names != null ? each.value.subject_alternative_names : []
  validation_method         = each.value.validation_method != null ? each.value.validation_method : "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(
    var.tags,
    each.value.tags != null ? each.value.tags : {},
    {
      Module       = "mtls"
      Certificate  = "public"
      MaterialType = "certificate-metadata"
    }
  )
}

resource "aws_route53_record" "public_validation" {
  for_each = local.validation_records

  allow_overwrite = true
  zone_id         = each.value.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

resource "aws_acm_certificate_validation" "public" {
  for_each = {
    for certificate_key, certificate in var.public_certificates :
    certificate_key => certificate
    if coalesce(certificate.wait_for_validation, false) && coalesce(certificate.create_route53_records, false)
  }

  certificate_arn = aws_acm_certificate.public[each.key].arn
  validation_record_fqdns = [
    for record_key, record in aws_route53_record.public_validation :
    record.fqdn
    if local.validation_records[record_key].certificate_key == each.key
  ]
}

resource "aws_acmpca_certificate_authority" "private" {
  for_each = var.private_cas

  type                            = each.value.type != null ? each.value.type : "ROOT"
  usage_mode                      = each.value.usage_mode != null ? each.value.usage_mode : "GENERAL_PURPOSE"
  permanent_deletion_time_in_days = each.value.permanent_deletion_time_in_days != null ? each.value.permanent_deletion_time_in_days : 30

  certificate_authority_configuration {
    key_algorithm     = each.value.key_algorithm != null ? each.value.key_algorithm : "RSA_2048"
    signing_algorithm = each.value.signing_algorithm != null ? each.value.signing_algorithm : "SHA256WITHRSA"

    subject {
      common_name         = each.value.subject.common_name
      organization        = each.value.subject.organization
      organizational_unit = each.value.subject.organizational_unit
      country             = each.value.subject.country
      state               = each.value.subject.state
      locality            = each.value.subject.locality
    }
  }

  tags = merge(
    var.tags,
    each.value.tags != null ? each.value.tags : {},
    {
      Module       = "mtls"
      Certificate  = "private-ca"
      MaterialType = "pca-metadata"
    }
  )
}

resource "aws_acmpca_permission" "this" {
  for_each = var.private_ca_permissions

  certificate_authority_arn = aws_acmpca_certificate_authority.private[each.value.ca_key].arn
  principal                 = each.value.principal
  actions                   = each.value.actions
}

resource "aws_ssm_parameter" "trust_bundle_metadata" {
  for_each = {
    for bundle_key, bundle in var.trust_bundles :
    bundle_key => bundle
    if coalesce(bundle.create_ssm_parameter, true)
  }

  name        = each.value.parameter_name != null ? each.value.parameter_name : "${local.trust_bundle_parameter_prefix}/${each.key}/metadata"
  description = each.value.description != null ? each.value.description : "Non-sensitive RBI mTLS trust bundle metadata for ${each.key}."
  type        = "String"
  value       = jsonencode(local.trust_bundle_metadata[each.key])

  tags = merge(
    var.tags,
    each.value.tags != null ? each.value.tags : {},
    {
      Module       = "mtls"
      MaterialType = "trust-bundle-metadata"
      Secret       = "false"
    }
  )
}
