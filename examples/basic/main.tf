# Core only, plus a read-only key for bring-your-own analysis (DuckDB etc.).

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

module "site_analytics" {
  source = "../../"

  sites = {
    "example-com" = {
      key     = "pk_example_01"
      origins = ["https://example.com", "https://www.example.com"]
    }
  }

  create_reader = true

  tags = {
    Project = "site-analytics"
  }
}

output "ingest_url" {
  value = module.site_analytics.ingest_url
}

output "events_s3_uri" {
  value = module.site_analytics.events_s3_uri
}

output "reader_ssm_parameters" {
  value = module.site_analytics.reader_ssm_parameters
}
