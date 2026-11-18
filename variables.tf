variable "name" {
  description = "Prefix for every resource name (bucket, stream, function, API, Glue database, Athena workgroup)."
  type        = string
  default     = "site-analytics"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name))
    error_message = "name: 3-31 chars, lowercase letters, digits and dashes, starting with a letter."
  }
}

variable "sites" {
  description = <<-EOT
    Sites allowed to send events, keyed by site id (the `site` partition value, e.g. "example-com").
    `key` is the public site key placed in the page (not a secret: it only routes events);
    `origins` are the exact page origins allowed to send for that key (https only).
  EOT
  type = map(object({
    key     = string
    origins = list(string)
  }))

  validation {
    condition     = length(var.sites) > 0 && alltrue([for id, s in var.sites : can(regex("^[a-z0-9][a-z0-9-]{0,39}$", id))])
    error_message = "sites: at least one; ids are 1-40 chars of lowercase letters, digits and dashes."
  }
  validation {
    condition     = alltrue([for s in values(var.sites) : can(regex("^[A-Za-z0-9_-]{8,40}$", s.key))])
    error_message = "sites[*].key: 8-40 chars of letters, digits, '_' and '-'."
  }
  validation {
    condition     = length(distinct([for s in values(var.sites) : s.key])) == length(var.sites)
    error_message = "sites[*].key must be unique."
  }
  validation {
    condition = alltrue(flatten([for s in values(var.sites) : [
      for o in s.origins : can(regex("^https://[a-z0-9.-]+(:[0-9]+)?$", o))
    ]])) && alltrue([for s in values(var.sites) : length(s.origins) > 0])
    error_message = "sites[*].origins: at least one, each https://host[:port] in lowercase with no path or trailing slash."
  }
}

variable "bucket_name" {
  description = "S3 bucket for events and Athena results. Null = <name>-<account id>-<region>."
  type        = string
  default     = null
}

variable "event_retention_days" {
  description = "Days raw events are kept in S3 before lifecycle expiry."
  type        = number
  default     = 90

  validation {
    condition     = var.event_retention_days >= 1
    error_message = "event_retention_days must be at least 1."
  }
}

variable "error_retention_days" {
  description = "Days Firehose error output (records it could not convert or deliver) is kept."
  type        = number
  default     = 30
}

variable "athena_results_retention_days" {
  description = "Days Athena query results are kept."
  type        = number
  default     = 7
}

variable "athena_bytes_scanned_cutoff" {
  description = "Per-query scan limit for the Athena workgroup, in bytes (Athena minimum 10 MB). A query over it is cancelled."
  type        = number
  default     = 1073741824 # 1 GiB

  validation {
    condition     = var.athena_bytes_scanned_cutoff >= 10485760
    error_message = "athena_bytes_scanned_cutoff: Athena's minimum is 10485760 (10 MB)."
  }
}

variable "projection_start_date" {
  description = "First date (yyyy-MM-dd) of the Glue partition projection range."
  type        = string
  default     = "2026-01-01"
}

variable "throttle_rate_limit" {
  description = "API Gateway steady-state requests per second for the ingest route (all clients together). Also the cost ceiling under abuse."
  type        = number
  default     = 5
}

variable "throttle_burst_limit" {
  description = "API Gateway burst limit for the ingest route."
  type        = number
  default     = 20
}

variable "lambda_reserved_concurrency" {
  description = "Reserved concurrency of the ingest function: a hard cap on parallel ingest work. -1 = unreserved."
  type        = number
  default     = 5
}

variable "max_body_bytes" {
  description = "Largest accepted beacon body, in bytes."
  type        = number
  default     = 16384
}

variable "max_events_per_batch" {
  description = "Most events accepted in one beacon."
  type        = number
  default     = 60
}

variable "firehose_buffer_seconds" {
  description = "Firehose buffer interval (60-900). Longer = fewer, larger Parquet files."
  type        = number
  default     = 900
}

variable "firehose_buffer_mb" {
  description = "Firehose buffer size in MB (64-128 with Parquet conversion and dynamic partitioning)."
  type        = number
  default     = 64
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the ingest function and Firehose errors."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Tags for every resource that takes them."
  type        = map(string)
  default     = {}
}

variable "custom_domain" {
  description = <<-EOT
    Optional custom domain for the ingest API (e.g. a subdomain of the tracked site), so the
    endpoint is known before apply and stays first party. Needs a Route 53 public zone in this
    account: the module creates a regional ACM certificate (DNS validated), the API domain
    name, the mapping and an alias record. Null = use the execute-api URL.
  EOT
  type = object({
    domain_name = string
    zone_id     = string
  })
  default = null
}

variable "alarm_topic_arn" {
  description = "SNS topic for the ingest-volume alarm. Null = no alarm."
  type        = string
  default     = null
}

variable "alarm_hourly_beacons" {
  description = "Ingest requests per hour above which the volume alarm fires."
  type        = number
  default     = 5000
}

# --------------------------------------------------------------------------- add-ons

variable "enable_athena" {
  description = "Add-on: Athena workgroup (with athena_bytes_scanned_cutoff) and partition projection on the Glue table, to query the events in place."
  type        = bool
  default     = false
}

variable "create_reader" {
  description = "Add-on: read-only IAM user for bring-your-own analysis (list + get on events/ only; plus Athena/Glue when enable_athena), access key in SSM SecureStrings."
  type        = bool
  default     = false
}

variable "reader_user_name" {
  description = "IAM user name for the reader. Null = <name>-reader."
  type        = string
  default     = null
}

variable "reader_ssm_prefix" {
  description = "SSM path prefix for the reader key: <prefix>/access_key_id and <prefix>/secret_access_key. Null = /<name>/reader."
  type        = string
  default     = null

  validation {
    condition     = var.reader_ssm_prefix == null || can(regex("^/[A-Za-z0-9_./-]+$", var.reader_ssm_prefix))
    error_message = "reader_ssm_prefix must start with / and use letters, digits, _ . / -."
  }
}
