output "ingest_url" {
  description = "Collector endpoint: the value for the script tag's data-endpoint."
  value = (var.custom_domain == null
    ? "${aws_apigatewayv2_api.this.api_endpoint}/e"
    : "https://${var.custom_domain.domain_name}/e"
  )
}

output "bucket_name" {
  description = "S3 bucket holding events, Firehose errors and Athena results."
  value       = aws_s3_bucket.this.bucket
}

output "glue_database" {
  description = "Glue database name."
  value       = aws_glue_catalog_database.this.name
}

output "glue_table" {
  description = "Glue table name (events)."
  value       = aws_glue_catalog_table.events.name
}

output "athena_workgroup" {
  description = "Athena workgroup name (enable_athena only; bytes-scanned cutoff enforced)."
  value       = var.enable_athena ? aws_athena_workgroup.this[0].name : null
}

output "firehose_stream_name" {
  description = "Firehose delivery stream name."
  value       = aws_kinesis_firehose_delivery_stream.events.name
}

output "ingest_function_name" {
  description = "Ingest Lambda function name."
  value       = aws_lambda_function.ingest.function_name
}

output "sites_parameter_name" {
  description = "SSM parameter holding the site list the ingest function reads."
  value       = aws_ssm_parameter.sites.name
}

output "reader_policy_json" {
  description = "IAM policy JSON for read-only access (S3 list/get on events/; plus Athena/Glue when enable_athena), to attach to your own role if you don't use create_reader."
  value       = data.aws_iam_policy_document.reader.json
}

output "events_s3_uri" {
  description = "Where the Parquet events land: s3://<bucket>/events/ (site=<id>/dt=<yyyy-MM-dd>/ below)."
  value       = "s3://${aws_s3_bucket.this.bucket}/events/"
}

output "reader_user_name" {
  description = "Reader IAM user (create_reader only)."
  value       = var.create_reader ? aws_iam_user.reader[0].name : null
}

output "reader_ssm_parameters" {
  description = "SSM SecureString names holding the reader key (create_reader only)."
  value = var.create_reader ? {
    access_key_id     = aws_ssm_parameter.reader_key_id[0].name
    secret_access_key = aws_ssm_parameter.reader_secret[0].name
  } : null
}
