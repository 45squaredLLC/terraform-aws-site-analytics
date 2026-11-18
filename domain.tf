# Optional custom domain for the ingest API (var.custom_domain).

resource "aws_acm_certificate" "ingest" {
  count             = var.custom_domain == null ? 0 : 1
  domain_name       = var.custom_domain.domain_name
  validation_method = "DNS"
  tags              = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "ingest_validation" {
  count           = var.custom_domain == null ? 0 : 1
  zone_id         = var.custom_domain.zone_id
  name            = tolist(aws_acm_certificate.ingest[0].domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.ingest[0].domain_validation_options)[0].resource_record_type
  records         = [tolist(aws_acm_certificate.ingest[0].domain_validation_options)[0].resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "ingest" {
  count                   = var.custom_domain == null ? 0 : 1
  certificate_arn         = aws_acm_certificate.ingest[0].arn
  validation_record_fqdns = [aws_route53_record.ingest_validation[0].fqdn]
}

resource "aws_apigatewayv2_domain_name" "ingest" {
  count       = var.custom_domain == null ? 0 : 1
  domain_name = var.custom_domain.domain_name
  tags        = var.tags

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.ingest[0].certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "ingest" {
  count       = var.custom_domain == null ? 0 : 1
  api_id      = aws_apigatewayv2_api.this.id
  domain_name = aws_apigatewayv2_domain_name.ingest[0].id
  stage       = aws_apigatewayv2_stage.default.id
}

resource "aws_route53_record" "ingest" {
  for_each = var.custom_domain == null ? {} : { A = "A", AAAA = "AAAA" }
  zone_id  = var.custom_domain.zone_id
  name     = var.custom_domain.domain_name
  type     = each.value

  alias {
    name                   = aws_apigatewayv2_domain_name.ingest[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.ingest[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}
