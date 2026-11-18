# Optional add-on (create_reader): a read-only IAM user for bring-your-own analysis
# (DuckDB, Spark, a sync job), with its access key in SSM SecureStrings.
#
# Scope: list the events/ prefix and get its objects. Nothing else in the bucket,
# no writes, no deletes. With enable_athena it may also run queries in the
# workgroup, read the Glue table and read/write its own query results.
#
# The access key is long-lived and its secret is in your Terraform state; protect
# the state backend and rotate the key (taint aws_iam_access_key.reader).

data "aws_iam_policy_document" "reader" {
  statement {
    sid       = "ListEvents"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["events/", "events/*"]
    }
  }

  statement {
    sid       = "ReadEvents"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/events/*"]
  }

  dynamic "statement" {
    for_each = var.enable_athena ? [1] : []
    content {
      sid = "AthenaInWorkgroup"
      actions = [
        "athena:StartQueryExecution",
        "athena:GetQueryExecution",
        "athena:GetQueryResults",
        "athena:StopQueryExecution",
        "athena:GetWorkGroup",
      ]
      resources = [aws_athena_workgroup.this[0].arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_athena ? [1] : []
    content {
      sid     = "GlueCatalogRead"
      actions = ["glue:GetDatabase", "glue:GetTable", "glue:GetPartitions", "glue:GetPartition"]
      resources = [
        "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
        "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.this.name}",
        "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.this.name}/*",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.enable_athena ? [1] : []
    content {
      sid       = "AthenaResultsBucket"
      actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
      resources = [aws_s3_bucket.this.arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_athena ? [1] : []
    content {
      sid       = "AthenaResults"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
      resources = ["${aws_s3_bucket.this.arn}/athena-results/*"]
    }
  }
}

resource "aws_iam_user" "reader" {
  count = var.create_reader ? 1 : 0
  name  = coalesce(var.reader_user_name, "${var.name}-reader")
  tags  = var.tags
}

resource "aws_iam_user_policy" "reader" {
  count  = var.create_reader ? 1 : 0
  name   = "${var.name}-read"
  user   = aws_iam_user.reader[0].name
  policy = data.aws_iam_policy_document.reader.json
}

resource "aws_iam_access_key" "reader" {
  count = var.create_reader ? 1 : 0
  user  = aws_iam_user.reader[0].name
}

resource "aws_ssm_parameter" "reader_key_id" {
  count       = var.create_reader ? 1 : 0
  name        = "${local.reader_ssm_prefix}/access_key_id"
  description = "Access key id for ${aws_iam_user.reader[0].name}"
  type        = "SecureString"
  value       = aws_iam_access_key.reader[0].id
  tags        = var.tags
}

resource "aws_ssm_parameter" "reader_secret" {
  count       = var.create_reader ? 1 : 0
  name        = "${local.reader_ssm_prefix}/secret_access_key"
  description = "Secret access key for ${aws_iam_user.reader[0].name}"
  type        = "SecureString"
  value       = aws_iam_access_key.reader[0].secret
  tags        = var.tags
}

locals {
  reader_ssm_prefix = trimsuffix(coalesce(var.reader_ssm_prefix, "/${var.name}/reader"), "/")
}
