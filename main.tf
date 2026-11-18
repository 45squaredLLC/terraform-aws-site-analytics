# Core storage.
#
#   S3   <bucket>/events/site=<id>/dt=<yyyy-MM-dd>/*.parquet   (Firehose writes, lifecycle expires)
#        <bucket>/errors/...                                     (Firehose conversion/delivery failures)
#        <bucket>/athena-results/...                             (only with enable_athena)
#
#   Glue database <name> + table events. Part of the core because Firehose's
#   JSON -> Parquet conversion reads its output schema from a Glue table; there is
#   no other way to give it one. It is metadata only (free tier, no crawler).
#   With enable_athena the same table also gets partition projection for Athena.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  bucket_name = coalesce(var.bucket_name, "${var.name}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}")
  glue_db     = replace(var.name, "-", "_")
  table       = "events"

  # Column order is the Parquet schema. `site` and `dt` are partition keys (from
  # the S3 path), not columns. Phase 2 (replay) adds a separate stream + table;
  # this one stays flat.
  columns = [
    { name = "v", type = "int", comment = "schema version" },
    { name = "sid", type = "string", comment = "random per-tab session id" },
    { name = "pv", type = "string", comment = "random page-view id" },
    { name = "seq", type = "int", comment = "event order within the page view" },
    { name = "t", type = "string", comment = "pv click rage dead scroll leave" },
    { name = "ts", type = "bigint", comment = "client time ms" },
    { name = "rts", type = "bigint", comment = "server receive time ms" },
    { name = "path", type = "string", comment = "URL path without query or fragment" },
    { name = "ref", type = "string", comment = "referrer host or empty" },
    { name = "dev", type = "string", comment = "d t m by viewport width" },
    { name = "vw", type = "int", comment = "viewport width" },
    { name = "vh", type = "int", comment = "viewport height" },
    { name = "dw", type = "int", comment = "document width" },
    { name = "dh", type = "int", comment = "document height" },
    { name = "x", type = "int", comment = "page x px" },
    { name = "y", type = "int", comment = "page y px" },
    { name = "nx", type = "double", comment = "x over document width" },
    { name = "ny", type = "double", comment = "y over document height" },
    { name = "sel", type = "string", comment = "CSS selector of the target" },
    { name = "tag", type = "string", comment = "target tag name" },
    { name = "n", type = "int", comment = "clicks in a rage burst" },
    { name = "depth", type = "int", comment = "max scroll depth percent" },
    { name = "dur", type = "bigint", comment = "visible time on page ms" },
  ]
}

# --------------------------------------------------------------------------- S3

resource "aws_s3_bucket" "this" {
  bucket = local.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3: no KMS key, no per-request KMS charge
    }
  }
}

resource "aws_s3_bucket_policy" "tls_only" {
  bucket = aws_s3_bucket.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-events"
    status = "Enabled"
    filter {
      prefix = "events/"
    }
    expiration {
      days = var.event_retention_days
    }
  }

  rule {
    id     = "expire-errors"
    status = "Enabled"
    filter {
      prefix = "errors/"
    }
    expiration {
      days = var.error_retention_days
    }
  }

  rule {
    id     = "expire-athena-results"
    status = "Enabled"
    filter {
      prefix = "athena-results/"
    }
    expiration {
      days = var.athena_results_retention_days
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# --------------------------------------------------------------------------- Glue

resource "aws_glue_catalog_database" "this" {
  name        = local.glue_db
  description = "Visitor analytics events (terraform-aws-site-analytics)"
}

resource "aws_glue_catalog_table" "events" {
  database_name = aws_glue_catalog_database.this.name
  name          = local.table
  table_type    = "EXTERNAL_TABLE"
  description   = "One row per collector event: the Parquet schema Firehose writes."

  parameters = merge(
    {
      "classification"      = "parquet"
      "EXTERNAL"            = "TRUE"
      "parquet.compression" = "SNAPPY"
    },
    var.enable_athena ? {
      "projection.enabled"          = "true"
      "projection.site.type"        = "enum"
      "projection.site.values"      = join(",", sort(keys(var.sites)))
      "projection.dt.type"          = "date"
      "projection.dt.format"        = "yyyy-MM-dd"
      "projection.dt.range"         = "${var.projection_start_date},NOW"
      "projection.dt.interval"      = "1"
      "projection.dt.interval.unit" = "DAYS"
      "storage.location.template"   = "s3://${aws_s3_bucket.this.bucket}/events/site=$${site}/dt=$${dt}/"
    } : {}
  )

  partition_keys {
    name = "site"
    type = "string"
  }
  partition_keys {
    name = "dt"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.this.bucket}/events/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters            = { "serialization.format" = "1" }
    }

    dynamic "columns" {
      for_each = local.columns
      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.comment
      }
    }
  }
}

