# Changelog

All notable changes to this module are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - unreleased

### Added

- Cookieless collector (clicks, rage clicks, dead clicks, scroll depth, time on
  page; nothing sent under Global Privacy Control or Do Not Track).
- Ingest: HTTP API with throttling and CORS, validating Lambda, Firehose to
  Parquet in S3 partitioned by site and date, lifecycle expiry, Glue table for
  the Parquet schema, optional custom domain and volume alarm.
- Add-ons: `enable_athena` (partition projection + scan-capped workgroup) and
  `create_reader` (read-only IAM user, key in SSM).
