# terraform-aws-site-analytics

Cookieless, first-party visitor analytics on AWS: click and scroll heatmaps,
scroll depth, rage clicks, dead clicks and time on page. A small browser
script, a serverless ingest path, and Parquet files in **your own S3 bucket**.
No third party sees your visitors.

**Bring your own analysis and presentation.** The module stores the data;
you read it with whatever you like: DuckDB on a laptop, a sync job into your
own database, Spark, or the optional Athena add-on. There is no hosted
dashboard to run or pay for.

```
page ── collector.js ──sendBeacon──▶ API Gateway (HTTP API)  POST /e
                                        │  throttled, CORS for your origins only
                                        ▼
                                     Lambda ingest  (validate, drop bots, no IP kept)
                                        │  one record per beacon
                                        ▼
                                     Data Firehose  (de-aggregate, partition by site,
                                        │            JSON -> Parquet using the Glue table's schema)
                                        ▼
                                     S3  events/site=<id>/dt=<yyyy-MM-dd>/*.parquet   (lifecycle expiry)
                                        │
                     ┌──────────────────┼────────────────────┐
                     ▼                  ▼                    ▼
              your DuckDB / sync   reader add-on         Athena add-on
              (bring your own)     (read-only key)       (scan-capped workgroup)
```

## What it builds

**Core (always):**

- `collector/collector.js`, the browser script you serve from your site.
- API Gateway HTTP API `POST /e` with stage throttling and CORS for your
  origins; optional custom domain (ACM certificate + Route 53 alias).
- The ingest Lambda (Python 3.12, arm64, reserved concurrency).
- A Data Firehose stream: de-aggregation, dynamic partitioning by site, Parquet (SNAPPY).
- An S3 bucket (public access blocked, SSE-S3, TLS only) with lifecycle expiry
  for events (default 90 days), Firehose errors and Athena results.
- A Glue database and table `events`. **Firehose's Parquet conversion needs
  it**: the conversion reads its output schema from a Glue table, and there is
  no other way to give Firehose one. It is catalog metadata only (no crawler,
  within the Glue free tier).
- Optional CloudWatch alarm on ingest volume (`alarm_topic_arn`).

**Add-ons (off by default):**

| Variable | Adds |
|---|---|
| `enable_athena = true` | Partition projection on the Glue table and an Athena workgroup with an enforced per-query scan cap (`athena_bytes_scanned_cutoff`). |
| `create_reader = true` | A read-only IAM user (list + get on `events/` only; plus Athena/Glue when `enable_athena`), its access key in SSM SecureStrings (`reader_ssm_prefix`). |

The `reader_policy_json` output is the same policy, if you'd rather attach it
to a role of your own.

## Privacy by design

- **No cookies, no cross-site id.** A random id per browser tab lives in
  `sessionStorage` and dies with the tab. A random id per page view.
- **Nothing typed or read.** No keystrokes, no input values, no text from the
  page. Click targets are described by a CSS selector built only from tag
  names, ids and class names that look hand-written (generated ones are
  skipped), and `:nth-of-type`.
- **Honours Global Privacy Control and Do Not Track:** the script sends
  nothing at all. Automated browsers (`navigator.webdriver`) send nothing.
- **No IP addresses.** The function never stores or logs the client IP or
  User-Agent; API Gateway access logging is off. Query strings and fragments
  are cut from paths; referrers are reduced to a host name.
- **Sampling:** `data-sample="0.25"` keeps a quarter of sessions (decided once
  per tab session).

## Security model

The endpoint is public by nature, so it fails closed:

- A **public site key** (not a secret; it is in the page) must be in the
  `sites` allowlist, and the request's `Origin` must be one of that key's
  origins. Anything else: 403.
- POST only, body capped (`max_body_bytes`, default 16 KB), at most
  `max_events_per_batch` events, every field checked against a fixed schema;
  unknown fields are dropped, a malformed event rejects the whole beacon.
- Crawlers and scripts (by User-Agent) are accepted and discarded.
- `Origin` can be forged outside a browser, so the **API throttle is the cost
  ceiling** (`throttle_rate_limit`), the function has reserved concurrency, and
  an optional CloudWatch alarm (`alarm_topic_arn`) fires on unusual volume.
- The ingest path is insert-only: it can write to Firehose and nothing else.
  The optional reader can list and read `events/` and nothing else (plus its
  own Athena results when the Athena add-on is on).
- S3: public access blocked, SSE-S3, TLS-only bucket policy. No KMS key needed.

## Usage

```hcl
module "site_analytics" {
  source = "github.com/45squaredLLC/terraform-aws-site-analytics?ref=v0.1.0"

  sites = {
    "example-com" = {
      key     = "pk_example_01"
      origins = ["https://example.com", "https://www.example.com"]
    }
  }

  custom_domain = { domain_name = "v.example.com", zone_id = "Z0123456789" } # optional
  create_reader = true                                                        # optional
  enable_athena = false                                                       # optional
  alarm_topic_arn = aws_sns_topic.alerts.arn                                  # optional
}
```

See `examples/basic` and `examples/with-athena`. Serve `collector/collector.js`
from your own site and add:

```html
<script defer src="/assets/collector.js"
        data-endpoint="https://v.example.com/e"
        data-key="pk_example_01"
        data-sample="1"></script>
```

## Event schema (v1)

One beacon = an envelope plus up to `max_events_per_batch` events:

```json
{"v":1,"k":"pk_example_01","sid":"s...","pv":"p...","p":"/pricing/","r":"www.google.com",
 "dev":"d","vw":1440,"vh":900,"dw":1440,"dh":4200,
 "e":[{"t":"pv","seq":0,"ts":1700000000000,"depth":21},
      {"t":"click","seq":1,"ts":...,"x":100,"y":300,"nx":0.07,"ny":0.071,"sel":"main > a#cta","tag":"a"}]}
```

| `t` | Meaning | Fields |
|---|---|---|
| `pv` | page view | `depth` (above-the-fold %) |
| `click` | any click | `x`,`y` (page px), `nx`,`ny` (0-1 of document), `sel`, `tag` |
| `rage` | 3+ clicks within 600 ms inside 30 px | as click + `n` |
| `dead` | click on a non-interactive element with no DOM change, navigation, scroll or text selection within 1 s | as click |
| `scroll` | crossed 25/50/75/90/100 % | `depth` |
| `leave` | tab hidden / page closed | `depth` (max %), `dur` (visible ms) |

The ingest function flattens the envelope into every event and adds `rts`
(server time). The Glue table `events` has those columns plus the partition
keys `site` and `dt`; queries must filter on `site` (and should on `dt`).

The ingest function flattens the envelope into every event and adds `rts`
(server time). Each Parquet row has those columns; `site` and `dt` are in the
S3 path (Hive style), not in the file.

## Bring your own analysis: DuckDB

Read the Parquet straight from S3 with the reader key (`create_reader = true`):

```sql
INSTALL httpfs; LOAD httpfs;
CREATE SECRET analytics (
  TYPE s3, KEY_ID '<access_key_id from SSM>', SECRET '<secret from SSM>', REGION 'us-west-2'
);

CREATE VIEW events AS
SELECT * FROM read_parquet(
  's3://<bucket>/events/site=example-com/dt=2026-11-*/*.parquet',
  hive_partitioning = true
);

-- Click heatmap for one page: 1% x 0.5% bins of page width/height
SELECT floor(nx * 100)::int AS bx, floor(ny * 200)::int AS by, count(*) AS clicks
FROM events
WHERE t = 'click' AND path = '/pricing/' AND dev = 'd'
GROUP BY ALL ORDER BY clicks DESC;

-- Scroll-depth curve: share of page views that reached each depth
WITH v AS (
  SELECT pv, max(depth) AS d FROM events
  WHERE path = '/pricing/' AND t IN ('pv', 'scroll', 'leave') GROUP BY pv
)
SELECT s AS depth, round(avg((d >= s)::int), 3) AS reached
FROM v, range(10, 101, 10) r(s) GROUP BY s ORDER BY s;

-- Rage and dead click hot spots
SELECT t, sel, count(*) AS n, count(DISTINCT sid) AS sessions
FROM events WHERE t IN ('rage', 'dead') GROUP BY ALL ORDER BY n DESC LIMIT 20;
```

For a dashboard, sync new objects on a schedule (list `events/` with
`StartAfter`, download only keys you haven't seen) into a local DuckDB file and
query that; an hourly sync of a small site moves a few MB a day.

## Athena (add-on)

With `enable_athena = true` the Glue table gets partition projection (no
crawler, no `MSCK REPAIR`) and the workgroup output `athena_workgroup` caps
every query at `athena_bytes_scanned_cutoff`. Queries must filter on `site`:

```sql
SELECT path, count_if(t = 'pv') AS views, count_if(t = 'rage') AS rage
FROM site_analytics.events
WHERE site = 'example-com' AND dt >= '2026-11-01'
GROUP BY path ORDER BY views DESC;
```

## Session replay (not built yet)

The schema leaves room for it: `sid`/`pv`/`seq` already order events within a
view. Replay would add an rrweb recorder (masking all inputs and text by
default), compressed rrweb chunks sent to a **separate** Firehose stream and S3
prefix (gzip JSON, not Parquet) with shorter retention, and a player. Keeping it
separate leaves this table, its cost and its privacy posture unchanged for
sites that never turn replay on.

## Cost

Assumptions: ~10 events and ~3 beacons (requests) per page view, one Firehose
record per beacon (billed as 5 KB), Firehose buffer 900 s, Parquet ~60 bytes
per event, an hourly bring-your-own sync. us-west-2 list prices; Firehose
format-conversion and dynamic-partitioning rates marked * are estimates.

| Line | Formula | 1k views/mo | 10k | 100k |
|---|---|---|---|---|
| API Gateway HTTP API | requests x $1.00/M | $0.003 | $0.03 | $0.30 |
| Lambda arm64 128 MB, ~40 ms | requests x ($0.20 + $0.067)/M | $0.001 | $0.008 | $0.08 |
| Firehose ingest | requests x 5 KB x $0.029/GB | <$0.001 | $0.004 | $0.04 |
| Firehose Parquet conversion* | same GB x $0.018/GB | <$0.001 | $0.003 | $0.03 |
| Firehose dynamic partitioning* | GB x $0.02 + objects x $0.005/1k + JQ hours x $0.07 | ~$0.005 | ~$0.02 | ~$0.05 |
| S3 PUTs + storage | <=2,900 objects x $0.005/1k + GB-mo x $0.023 | ~$0.005 | ~$0.015 | ~$0.02 |
| S3 LIST + GET for an hourly sync | ~1,500 LIST x $0.005/1k + <=2,900 GET x $0.0004/1k | ~$0.008 | ~$0.008 | ~$0.008 |
| S3 egress to the sync | Parquet MB x $0.09/GB (first 100 GB/mo free per account) | ~$0 | ~$0.001 | ~$0.006 |
| Glue Data Catalog | free tier, no crawler | $0 | $0 | $0 |
| CloudWatch Logs | ~350 B/request x $0.50/GB | <$0.001 | $0.005 | $0.05 |
| CloudWatch alarm (optional) | 1 x $0.10 | $0.10 | $0.10 | $0.10 |
| KMS, ACM, Route 53 alias | none / free / free | $0 | $0 | $0 |
| **Total** | | **~$0.12** | **~$0.19** | **~$0.68** |
| Athena add-on (optional) | queries x max(10 MB, scanned) x $5/TB | ~$0.01 | ~$0.01 | ~$0.05 |

Worst case under a flood at the default throttle (5 req/s sustained, ~13M
requests/month, max-size beacons): about $13 API Gateway + $3.50 Lambda +
$22 Firehose + $2 logs = **~$40/month**, and the alarm fires within the hour.

## Tests

```bash
node --test tests/collector.test.js
python -m pytest tests -q
terraform init -backend=false && terraform test   # mocked providers, no AWS calls
```

## License

MIT, see `LICENSE`.
