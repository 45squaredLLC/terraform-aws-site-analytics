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
    condition     = jsondecode(aws_lambda_function.ingest.environment[0].variables.SITES_JSON)["pk_example_01"].site == "example-com"
    error_message = "SITES_JSON maps the public key to the site id"
  }
  assert {
    condition     = length(aws_apigatewayv2_api.this.cors_configuration[0].allow_origins) == 3
    error_message = "CORS allows exactly the listed origins"
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
