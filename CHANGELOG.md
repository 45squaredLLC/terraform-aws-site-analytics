# Changelog

All notable changes to this module are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-11-18

### Fixed

- Ingest cold starts no longer time out and drop the beacon. At 128 MB / 5 s
  the first request after a cold start ran 4.5-5 s (Python init, SDK client,
  TLS to Firehose on a fractional vCPU) and often hit the timeout, so 40-50%
  of invocations on low-traffic sites errored.
  - Defaults raised to 512 MB and 15 s, now inputs `lambda_memory_size` and
    `lambda_timeout`. The API Gateway integration timeout follows
    `lambda_timeout` (+1 s, at most 30 s).
  - The Firehose client is created at import, in the init phase, with
    `connect_timeout=2`, `read_timeout=5` and botocore standard retries
    (`max_attempts=2`), so one slow connection cannot use up the whole
    budget. The handler no longer adds its own retry on top.

## [0.1.0] - 2026-11-17

### Added

- Cookieless collector (clicks, rage clicks, dead clicks, scroll depth, time on
  page; nothing sent under Global Privacy Control or Do Not Track).
- Ingest: HTTP API with throttling and CORS, validating Lambda, Firehose to
  Parquet in S3 partitioned by site and date, lifecycle expiry, Glue table for
  the Parquet schema, optional custom domain and volume alarm.
- Add-ons: `enable_athena` (partition projection + scan-capped workgroup) and
  `create_reader` (read-only IAM user, key in SSM).
