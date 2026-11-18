# site-analytics: ingest side.
#
#   browser --sendBeacon--> API Gateway HTTP API  POST /e  (throttled, CORS for listed origins)
#           --> Lambda ingest (validates, drops bots, no IP stored)
#           --> Firehose (dynamic partitioning on site, JSON -> Parquet via the Glue table)
#           --> S3 events/site=<id>/dt=<date>/
#
# Why a Lambda and not a direct API Gateway -> Firehose integration: HTTP APIs have
# no Firehose integration, and a REST API's VTL mapping cannot check the Origin
# against the key's own origin list, clamp/strip each field, or split a batch into
# records cleanly. The function is ~200 lines with tests and costs cents at this
# volume.

locals {
  sites_json = jsonencode({
    for id, s in var.sites : s.key => { site = id, origins = [for o in s.origins : lower(o)] }
  })
  all_origins = sort(distinct(flatten([for s in values(var.sites) : [for o in s.origins : lower(o)]])))
}

# --------------------------------------------------------------------------- Firehose

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "DestinationDelivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${var.name}-firehose"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "firehose" {
  statement {
    sid = "WriteEvents"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
  }
  statement {
    sid     = "ReadSchema"
    actions = ["glue:GetTable", "glue:GetTableVersion", "glue:GetTableVersions"]
    resources = [
      "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.this.name}",
      "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.this.name}/${aws_glue_catalog_table.events.name}",
    ]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.firehose.arn}:*"]
  }
}

resource "aws_iam_role_policy" "firehose" {
  name   = "deliver"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose.json
}

resource "aws_kinesis_firehose_delivery_stream" "events" {
  name        = var.name
  destination = "extended_s3"
  tags        = var.tags

  server_side_encryption {
    enabled  = true
    key_type = "AWS_OWNED_CMK"
  }

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.this.arn
    prefix              = "events/site=!{partitionKeyFromQuery:site}/dt=!{timestamp:yyyy-MM-dd}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/"
    buffering_interval  = var.firehose_buffer_seconds
    buffering_size      = var.firehose_buffer_mb

    dynamic_partitioning_configuration {
      enabled = true
    }

    processing_configuration {
      enabled = true
      # The ingest function sends one record per beacon (newline-delimited
      # events, cheaper: Firehose bills each record rounded up to 5 KB). Split
      # it back into one record per event first.
      processors {
        type = "RecordDeAggregation"
        parameters {
          parameter_name  = "SubRecordType"
          parameter_value = "JSON"
        }
      }
      processors {
        type = "MetadataExtraction"
        parameters {
          parameter_name  = "JsonParsingEngine"
          parameter_value = "JQ-1.6"
        }
        parameters {
          parameter_name  = "MetadataExtractionQuery"
          parameter_value = "{site:.site}"
        }
      }
    }

    data_format_conversion_configuration {
      enabled = true
      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }
      output_format_configuration {
        serializer {
          parquet_ser_de {
            compression = "SNAPPY"
          }
        }
      }
      schema_configuration {
        database_name = aws_glue_catalog_database.this.name
        table_name    = aws_glue_catalog_table.events.name
        role_arn      = aws_iam_role.firehose.arn
        region        = data.aws_region.current.name
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }
  }

  depends_on = [aws_iam_role_policy.firehose]
}

# --------------------------------------------------------------------------- Lambda

data "archive_file" "ingest" {
  type             = "zip"
  output_path      = "${path.module}/.build/${var.name}-ingest.zip"
  output_file_mode = "0666" # stable hash across checkouts with different file modes

  source {
    filename = "ingest.py"
    content  = file("${path.module}/lambda/ingest.py")
  }
}

resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${var.name}-ingest"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ingest" {
  name               = "${var.name}-ingest"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "ingest" {
  statement {
    sid       = "PutEvents"
    actions   = ["firehose:PutRecord"]
    resources = [aws_kinesis_firehose_delivery_stream.events.arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ingest.arn}:*"]
  }
}

resource "aws_iam_role_policy" "ingest" {
  name   = "ingest"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest.json
}

resource "aws_lambda_function" "ingest" {
  function_name                  = "${var.name}-ingest"
  description                    = "Validates collector beacons and forwards them to Firehose"
  filename                       = data.archive_file.ingest.output_path
  source_code_hash               = data.archive_file.ingest.output_base64sha256
  role                           = aws_iam_role.ingest.arn
  handler                        = "ingest.handler"
  runtime                        = "python3.12"
  architectures                  = ["arm64"]
  memory_size                    = var.lambda_memory_size
  timeout                        = var.lambda_timeout
  reserved_concurrent_executions = var.lambda_reserved_concurrency
  tags                           = var.tags

  environment {
    variables = {
      STREAM_NAME    = aws_kinesis_firehose_delivery_stream.events.name
      SITES_JSON     = local.sites_json
      MAX_BODY_BYTES = tostring(var.max_body_bytes)
      MAX_EVENTS     = tostring(var.max_events_per_batch)
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingest, aws_iam_role_policy.ingest]
}

# --------------------------------------------------------------------------- API Gateway

resource "aws_apigatewayv2_api" "this" {
  name          = var.name
  description   = "Visitor analytics beacon ingest"
  protocol_type = "HTTP"
  tags          = var.tags

  # sendBeacon posts text/plain (a CORS "simple" request, no preflight). This
  # covers the fetch(keepalive) fallback and any preflight a browser does send.
  cors_configuration {
    allow_origins     = local.all_origins
    allow_methods     = ["POST"]
    allow_headers     = ["content-type"]
    max_age           = 86400
    allow_credentials = false
  }
}

resource "aws_apigatewayv2_integration" "ingest" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ingest.invoke_arn
  payload_format_version = "2.0"
  # One second past the function timeout, so API Gateway never gives up on a
  # call the function is still finishing.
  timeout_milliseconds = min((var.lambda_timeout + 1) * 1000, 30000)
}

resource "aws_apigatewayv2_route" "ingest" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /e"
  target    = "integrations/${aws_apigatewayv2_integration.ingest.id}"
}

# No access logging on purpose: API Gateway access logs would record client IPs.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
  tags        = var.tags

  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/POST/e"
}

# --------------------------------------------------------------------------- abuse alarm

# Origin can be forged by a non-browser client, so a flood is possible within the
# API throttle. This alarm says so within the hour; the response is to lower the
# throttle or rotate the site key.
resource "aws_cloudwatch_metric_alarm" "ingest_volume" {
  count               = var.alarm_topic_arn == null ? 0 : 1
  alarm_name          = "${var.name}-ingest-volume"
  alarm_description   = "Visitor analytics beacons above the expected hourly volume: possible flood. Lower the API throttle or rotate the site key."
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  dimensions          = { FunctionName = aws_lambda_function.ingest.function_name }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = var.alarm_hourly_beacons
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
  tags                = var.tags
}
