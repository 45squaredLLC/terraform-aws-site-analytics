# Input guards and wiring. Mocked providers, no AWS calls:
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "us-west-2" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock" }
  }
  mock_resource "aws_kinesis_firehose_delivery_stream" {
    defaults = { arn = "arn:aws:firehose:us-west-2:123456789012:deliverystream/mock" }
  }
  mock_resource "aws_ssm_parameter" {
    defaults = { arn = "arn:aws:ssm:us-west-2:123456789012:parameter/site-analytics/sites" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-west-2:123456789012:log-group:mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn        = "arn:aws:lambda:us-west-2:123456789012:function:mock"
      invoke_arn = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:mock/invocations"
    }
  }
  mock_resource "aws_athena_workgroup" {
    defaults = { arn = "arn:aws:athena:us-west-2:123456789012:workgroup/mock" }
  }
  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      api_endpoint  = "https://abc123.execute-api.us-west-2.amazonaws.com"
      execution_arn = "arn:aws:execute-api:us-west-2:123456789012:abc123"
    }
  }
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-west-2:123456789012:certificate/mock"
      domain_validation_options = [{
        domain_name           = "v.example.com"
        resource_record_name  = "_x.v.example.com."
        resource_record_type  = "CNAME"
        resource_record_value = "_y.acm-validations.aws."
      }]
    }
  }
}
mock_provider "archive" {}

variables {
  name = "site-analytics"
  sites = {
    "example-com" = { key = "pk_example_01", origins = ["https://example.com", "https://www.example.com"] }
    "other-org"   = { key = "pk_other_0001", origins = ["https://other.org"] }
  }
}

run "core_only" {
  command = apply

  assert {
    condition     = jsondecode(aws_ssm_parameter.sites.value)["pk_example_01"].site == "example-com"
    error_message = "the site list maps the public key to the site id"
  }
  assert {
    condition     = aws_ssm_parameter.sites.name == "/site-analytics/sites" && aws_ssm_parameter.sites.type == "String" && aws_ssm_parameter.sites.tier == "Standard"
    error_message = "the site list is one Standard String parameter under /<name>/"
  }
  assert {
    condition     = aws_lambda_function.ingest.environment[0].variables.SITES_PARAM == "/site-analytics/sites" && aws_lambda_function.ingest.environment[0].variables.SITES_TTL_SECONDS == "300"
    error_message = "the function is told which parameter to read and how long to cache it"
  }
  assert {
    condition     = !contains(keys(aws_lambda_function.ingest.environment[0].variables), "SITES_JSON")
    error_message = "the site list is no longer in the function's environment (4 KB cap)"
  }
  assert {
    condition = one([
      for s in data.aws_iam_policy_document.ingest.statement :
      join(",", s.actions) == "ssm:GetParameter" && join(",", s.resources) == aws_ssm_parameter.sites.arn && s.effect != "Deny"
      if s.sid == "ReadSiteList"
    ])
    error_message = "the ingest role may read exactly the one site-list parameter"
  }
  assert {
    condition     = length([for s in data.aws_iam_policy_document.ingest.statement : s if anytrue([for a in s.actions : startswith(a, "ssm:")])]) == 1
    error_message = "no other SSM permission on the ingest role"
  }
  assert {
    condition     = aws_apigatewayv2_stage.default.default_route_settings[0].throttling_rate_limit == 5 && aws_apigatewayv2_stage.default.default_route_settings[0].throttling_burst_limit == 20
    error_message = "the default throttle stays at 5 req/s, burst 20"
  }
  assert {
    condition     = output.sites_parameter_name == "/site-analytics/sites"
    error_message = "the parameter name is an output"
  }
  assert {
    condition     = length(aws_apigatewayv2_api.this.cors_configuration[0].allow_origins) == 3
    error_message = "CORS allows exactly the listed origins"
  }
  assert {
    condition     = aws_lambda_function.ingest.memory_size == 512 && aws_lambda_function.ingest.timeout == 15
    error_message = "ingest defaults to 512 MB / 15 s so a cold start fits"
  }
  assert {
    condition     = aws_apigatewayv2_integration.ingest.timeout_milliseconds == 16000
    error_message = "API Gateway waits one second past the function timeout"
  }
  assert {
    condition     = output.ingest_url == "https://abc123.execute-api.us-west-2.amazonaws.com/e"
    error_message = "ingest URL ends in /e"
  }
  assert {
    condition     = length(aws_athena_workgroup.this) == 0 && !contains(keys(aws_glue_catalog_table.events.parameters), "projection.enabled")
    error_message = "Athena is an add-on, off by default"
  }
  assert {
    condition     = length(aws_iam_user.reader) == 0 && output.reader_ssm_parameters == null
    error_message = "the reader is an add-on, off by default"
  }
  assert {
    condition     = length(aws_glue_catalog_table.events.storage_descriptor[0].columns) == 23
    error_message = "the Glue table (Firehose's Parquet schema) is always there"
  }
}

run "with_athena_and_reader" {
  command = apply
  variables {
    enable_athena     = true
    create_reader     = true
    reader_user_name  = "analytics-reader"
    reader_ssm_prefix = "/team/analytics-reader"
  }

  assert {
    condition     = aws_athena_workgroup.this[0].configuration[0].enforce_workgroup_configuration == true
    error_message = "the workgroup's scan cap cannot be overridden by a client"
  }
  assert {
    condition     = aws_glue_catalog_table.events.parameters["projection.site.values"] == "example-com,other-org"
    error_message = "partition projection lists every site id"
  }
  assert {
    condition     = aws_iam_user.reader[0].name == "analytics-reader"
    error_message = "reader user name"
  }
  assert {
    condition     = output.reader_ssm_parameters.secret_access_key == "/team/analytics-reader/secret_access_key"
    error_message = "reader key in SSM under the prefix"
  }
}

run "rejects_http_origin" {
  command = plan
  variables {
    sites = { "example-com" = { key = "pk_example_01", origins = ["http://example.com"] } }
  }
  expect_failures = [var.sites]
}

run "rejects_trailing_slash_origin" {
  command = plan
  variables {
    sites = { "example-com" = { key = "pk_example_01", origins = ["https://example.com/"] } }
  }
  expect_failures = [var.sites]
}

run "rejects_short_key" {
  command = plan
  variables {
    sites = { "example-com" = { key = "abc", origins = ["https://example.com"] } }
  }
  expect_failures = [var.sites]
}

run "rejects_duplicate_keys" {
  command = plan
  variables {
    sites = {
      "a-com" = { key = "pk_same_key_1", origins = ["https://a.com"] }
      "b-com" = { key = "pk_same_key_1", origins = ["https://b.com"] }
    }
  }
  expect_failures = [var.sites]
}

# 40 sites: over Lambda's 4 KB environment cap, so the list needs an Advanced parameter.
run "forty_sites_fit" {
  command = apply
  variables {
    sites = { for i in range(40) : format("client-site-%02d-example-com", i) => {
      key     = format("pk_client_site_%04d", i)
      origins = [format("https://client-site-%02d.example.com", i), format("https://www.client-site-%02d.example.com", i)]
    } }
    sites_parameter_name  = "/team/analytics/sites"
    sites_refresh_seconds = 60
    throttle_rate_limit   = 25
    throttle_burst_limit  = 50
  }

  assert {
    condition     = length(aws_ssm_parameter.sites.value) > 4096 && aws_ssm_parameter.sites.tier == "Advanced"
    error_message = "a list over 4 KB is stored as an Advanced parameter"
  }
  assert {
    condition     = length(jsondecode(aws_ssm_parameter.sites.value)) == 40
    error_message = "every site is in the list"
  }
  assert {
    condition     = aws_ssm_parameter.sites.name == "/team/analytics/sites" && aws_lambda_function.ingest.environment[0].variables.SITES_PARAM == "/team/analytics/sites"
    error_message = "sites_parameter_name is used for the parameter and passed to the function"
  }
  assert {
    condition     = aws_lambda_function.ingest.environment[0].variables.SITES_TTL_SECONDS == "60"
    error_message = "sites_refresh_seconds reaches the function"
  }
  assert {
    condition     = aws_apigatewayv2_stage.default.default_route_settings[0].throttling_rate_limit == 25 && aws_apigatewayv2_stage.default.default_route_settings[0].throttling_burst_limit == 50
    error_message = "throttle inputs reach the stage"
  }
}

run "rejects_a_list_over_one_parameter" {
  command = plan
  variables {
    sites = { for i in range(100) : format("client-site-%03d-example-com", i) => {
      key     = format("pk_client_site_%04d", i)
      origins = [format("https://client-site-%03d.example.com", i), format("https://www.client-site-%03d.example.com", i)]
    } }
  }
  expect_failures = [aws_ssm_parameter.sites]
}

run "rejects_zero_throttle" {
  command = plan
  variables {
    throttle_rate_limit = 0
  }
  expect_failures = [var.throttle_rate_limit]
}

run "rejects_bad_parameter_name" {
  command = plan
  variables {
    sites_parameter_name = "site-analytics/sites"
  }
  expect_failures = [var.sites_parameter_name]
}

run "rejects_tiny_scan_cap" {
  command = plan
  variables {
    athena_bytes_scanned_cutoff = 1000
  }
  expect_failures = [var.athena_bytes_scanned_cutoff]
}

run "custom_domain" {
  command = apply
  variables {
    custom_domain = { domain_name = "v.example.com", zone_id = "Z123EXAMPLE" }
  }
  assert {
    condition     = output.ingest_url == "https://v.example.com/e"
    error_message = "with a custom domain the ingest URL uses it"
  }
  assert {
    condition     = length(aws_route53_record.ingest) == 2
    error_message = "A and AAAA alias records"
  }
}
