# Changelog

All notable changes to this module are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Collector, single-page apps: clicks were filed under the wrong path. The
  envelope (path, page-view id) was built when the queue was flushed and the
  page-view id never changed, so on a site that routes with the History API a
  click on one route could be stored under the next. A path change through
  `pushState`, `replaceState` or back/forward now sends what is queued under
  the old path and starts a new page view. Multi-page sites behave as before.
- Collector, dead clicks: a carousel or animation anywhere on the page counted
  as "the page reacted", so dead clicks went unreported on busy pages. A DOM
  change now only counts when it is on the clicked element, inside it or on
  one of its ancestors.
- README: removed a duplicated paragraph that gave two different accounts of
  the Glue columns (`site` and `dt` are partition keys from the S3 path, not
  columns in the Parquet files), and corrected the claim that Athena queries
  must filter on `site`.

### Changed

- The site list moved from the function's `SITES_JSON` environment variable
  (Lambda caps the environment at 4 KB, about 30 sites) to one SSM parameter,
  `/<name>/sites`, read in the init phase and cached for
  `sites_refresh_seconds`. Holds about 60 sites; a site change no longer
  redeploys the function. An unreadable or malformed list rejects every
  beacon with 503. The ingest role gains `ssm:GetParameter` on that one
  parameter. No input changes for existing callers; see "Upgrading" in the
  README for the permissions the applying role needs.
- New inputs `sites_parameter_name` and `sites_refresh_seconds`, new output
  `sites_parameter_name`. `throttle_rate_limit` and `throttle_burst_limit`
  must be above 0 (defaults unchanged: 5 and 20).

### Documentation

- README: the throttle is shared by every site in a stack; what to set for
  15 to 30 sites and what it does to the flood cost ceiling.
- README: the default reserved concurrency can fail to apply in a new AWS
  account whose concurrency limit is still 10.

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
