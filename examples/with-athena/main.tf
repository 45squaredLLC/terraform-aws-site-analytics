# Custom first-party endpoint, Athena add-on, volume alarm.

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

variable "zone_id" {
  description = "Route 53 public hosted zone of example.com"
  type        = string
}

resource "aws_sns_topic" "alerts" {
  name = "site-analytics-alerts"
}

module "site_analytics" {
  source = "../../"

  sites = {
    "example-com" = {
      key     = "pk_example_01"
      origins = ["https://example.com", "https://www.example.com"]
    }
  }

  custom_domain = {
    domain_name = "v.example.com"
    zone_id     = var.zone_id
  }

  enable_athena               = true
  athena_bytes_scanned_cutoff = 1073741824 # 1 GiB per query
  create_reader               = true

  alarm_topic_arn      = aws_sns_topic.alerts.arn
  alarm_hourly_beacons = 5000
}

output "ingest_url" {
  value = module.site_analytics.ingest_url
}

output "athena_workgroup" {
  value = module.site_analytics.athena_workgroup
}
