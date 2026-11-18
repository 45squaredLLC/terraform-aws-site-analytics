# Optional add-on (enable_athena): query the events in place with Athena.
# Partition projection on the Glue table (main.tf) + a workgroup whose
# per-query scan cap cannot be overridden by clients.

resource "aws_athena_workgroup" "this" {
  count         = var.enable_athena ? 1 : 0
  name          = var.name
  description   = "Visitor analytics queries, capped per query"
  force_destroy = false
  tags          = var.tags

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_bytes_scanned_cutoff

    result_configuration {
      output_location = "s3://${aws_s3_bucket.this.bucket}/athena-results/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

