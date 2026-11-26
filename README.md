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
- The ingest Lambda (Python 3.12, arm64, reserved concurrency; 512 MB and 15 s by
  default, `lambda_memory_size` / `lambda_timeout`). Below 512 MB a cold start
  can take ~5 s on Lambda's fractional CPU, and a beacon that times out is lost.
- The site list as one SSM parameter (`/<name>/sites`), which the function
  reads at start-up and re-reads every `sites_refresh_seconds` (default 300).
  See [Many sites in one stack](#many-sites-in-one-stack).
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
  origins. Anything else: 403. If the site list cannot be read or is
  malformed, every beacon is rejected (503) until it can be read again; the
  function never falls back to accepting everything or to an older copy.
- POST only, body capped (`max_body_bytes`, default 16 KB), at most
  `max_events_per_batch` events, every field checked against a fixed schema;
  unknown fields are dropped, a malformed event rejects the whole beacon.
- Crawlers and scripts (by User-Agent) are accepted and discarded.
- `Origin` can be forged outside a browser, so the **API throttle is the cost
  ceiling** (`throttle_rate_limit`), the function has reserved concurrency, and
  an optional CloudWatch alarm (`alarm_topic_arn`) fires on unusual volume.
- The ingest path is insert-only: it can write to Firehose, read its own
  site-list parameter (`ssm:GetParameter` on that one ARN) and nothing else.
  The optional reader can list and read `events/` and nothing else (plus its
  own Athena results when the Athena add-on is on).
- S3: public access blocked, SSE-S3, TLS-only bucket policy. No KMS key needed.

## Usage

```hcl
module "site_analytics" {
  source = "github.com/45squaredLLC/terraform-aws-site-analytics?ref=v0.2.0"

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
| `dead` | click on a non-interactive element with no reaction within 1 s: no DOM change on the element, inside it or on one of its ancestors, and no navigation, scroll or text selection | as click |
| `scroll` | crossed 25/50/75/90/100 % | `depth` |
| `leave` | tab hidden / page closed | `depth` (max %), `dur` (visible ms) |

The ingest function flattens the envelope into every event and adds `rts`
(server time). Each Parquet row has those columns; `site` and `dt` are in the
S3 path (Hive style), not in the file. The Glue table `events` declares them
as partition keys, not as columns.

**Dead clicks and moving pages.** A change only counts as the page reacting
when it touches the clicked element, something inside it, or one of its
ancestors (a class on `<body>` when a dialog opens, for example). A carousel,
ticker or animation elsewhere on the page changes the DOM all the time and no
longer hides dead clicks. The trade-off: a click whose only effect is in an
unrelated part of the page, with nothing changing on the clicked element or
its ancestors, is reported as dead.

**Single-page apps.** When the path changes through `history.pushState`,
`history.replaceState` or back/forward, the collector closes the current page
view (a `leave` event, and everything queued is sent under the old path) and
starts a new one: new `pv` id, `seq` from 0, scroll depth from the top, empty
`r`. A change to the query string or fragment alone is not a new page view,
so apps that route on `#/...` are still one page view per load. Multi-page
sites are unaffected.

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
every query at `athena_bytes_scanned_cutoff`. Filter on `site` and `dt` so a
query reads only the partitions it needs:

```sql
SELECT path, count_if(t = 'pv') AS views, count_if(t = 'rage') AS rage
FROM site_analytics.events
WHERE site = 'example-com' AND dt >= '2026-11-01'
GROUP BY path ORDER BY views DESC;
```

## Many sites in one stack

The `sites` input is stored as JSON in one SSM parameter (`/<name>/sites`, or
`sites_parameter_name`), not in the function's environment, which Lambda caps
at 4 KB in total (about 30 sites). The parameter is a Standard one up to 4 KB
and an Advanced one ($0.05/month) up to 8 KB, which is about 60 sites; past
that `terraform plan` fails with a message, and the answer is a second stack.
It is a plain `String`: site keys are public, so nothing in it is secret.

Adding or removing a site is still a change to `sites` and a `terraform
apply` (the API's CORS origins and the Athena partition projection come from
the same input), but the function is no longer redeployed: it picks the new
list up within `sites_refresh_seconds` (default 300, so allow five minutes
before testing a new site).

### Throttle: one limit for every site

`throttle_rate_limit` (default 5 requests per second) and
`throttle_burst_limit` (default 20) apply to the ingest route as a whole.
Every site in the stack shares them; there is no per-site or per-key limit.
The trade-off:

- **Too low** and sites compete. A request over the limit gets a 429, and the
  browser does not retry a beacon, so those events are lost. One busy site,
  or several sites peaking together, can cost the others data.
- **Too high** and a flood costs more, because the throttle is the cost
  ceiling (`Origin` can be forged outside a browser). The worst case in
  [Cost](#cost) is about $43/month for every 5 requests per second sustained
  all month, and it scales in a straight line.

Average load is rarely the issue: at ~3 beacons per page view, 100k page
views a month is about 0.1 requests per second. Peaks are, and they add up
across sites. The defaults suit a handful of small sites. For 15 to 30 sites
in one stack:

```hcl
throttle_rate_limit  = 20   # 20 to 25
throttle_burst_limit = 40
alarm_topic_arn      = aws_sns_topic.alerts.arn
alarm_hourly_beacons = 20000 # a few times your busiest normal hour
```

That moves the flood ceiling to roughly $170 to $215 a month (4x to 5x the
$43), so set `alarm_topic_arn` when you raise it: the alarm fires within the
hour, long before a month of that. `alarm_hourly_beacons` counts requests
for all sites together (default 5,000); the 20,000 above is a placeholder, so
set it from your own traffic. The reserved concurrency of 5 does not need to
rise with the throttle: at ~40 ms per request five instances serve far more
than 25 requests per second.

### Reserved concurrency in a new AWS account

`lambda_reserved_concurrency` defaults to 5. A new AWS account can start with
an account-wide Lambda concurrency limit of 10, and Lambda will not let any
function reserve concurrency while the limit is that low, so the apply fails
on the function with an error about `ReservedConcurrentExecutions` and the
account's unreserved minimum. Either ask for a higher "Concurrent executions"
quota in Service Quotas first, or set `lambda_reserved_concurrency = -1` until
it is granted. With `-1` the function has no cap of its own and the API
throttle is the only limit.

## Upgrading

### From 0.1.x

No input changes are needed; `sites` keeps its shape. The next apply:

- creates the SSM parameter `/<name>/sites`. The role that runs Terraform
  needs `ssm:PutParameter`, `ssm:GetParameter`, `ssm:DescribeParameters`,
  `ssm:ListTagsForResource`, `ssm:AddTagsToResource` and
  `ssm:DeleteParameter` for it, if that role is scoped tightly;
- adds `ssm:GetParameter` on that parameter to the ingest role;
- updates the function: `SITES_JSON` leaves its environment, `SITES_PARAM` and
  `SITES_TTL_SECONDS` arrive.

If the function starts before the new IAM permission has propagated, it
rejects beacons with 503 and tries again every 15 seconds, so expect at most
a brief gap right after the apply. Serve the new `collector/collector.js`
from your sites to get the single-page-app and dead-click fixes; the event
schema is unchanged (`v` stays 1), so old and new collectors can run side by
side.

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
| Lambda arm64 512 MB, ~40 ms | requests x ($0.20 + $0.27)/M | $0.001 | $0.014 | $0.14 |
| Firehose ingest | requests x 5 KB x $0.029/GB | <$0.001 | $0.004 | $0.04 |
| Firehose Parquet conversion* | same GB x $0.018/GB | <$0.001 | $0.003 | $0.03 |
| Firehose dynamic partitioning* | GB x $0.02 + objects x $0.005/1k + JQ hours x $0.07 | ~$0.005 | ~$0.02 | ~$0.05 |
| S3 PUTs + storage | <=2,900 objects x $0.005/1k + GB-mo x $0.023 | ~$0.005 | ~$0.015 | ~$0.02 |
| S3 LIST + GET for an hourly sync | ~1,500 LIST x $0.005/1k + <=2,900 GET x $0.0004/1k | ~$0.008 | ~$0.008 | ~$0.008 |
| S3 egress to the sync | Parquet MB x $0.09/GB (first 100 GB/mo free per account) | ~$0 | ~$0.001 | ~$0.006 |
| Glue Data Catalog | free tier, no crawler | $0 | $0 | $0 |
| SSM parameter (site list) | Standard: free; Advanced (list over 4 KB): $0.05 | $0 | $0 | $0 |
| CloudWatch Logs | ~350 B/request x $0.50/GB | <$0.001 | $0.005 | $0.05 |
| CloudWatch alarm (optional) | 1 x $0.10 | $0.10 | $0.10 | $0.10 |
| KMS, ACM, Route 53 alias | none / free / free | $0 | $0 | $0 |
| **Total** | | **~$0.12** | **~$0.20** | **~$0.74** |
| Athena add-on (optional) | queries x max(10 MB, scanned) x $5/TB | ~$0.01 | ~$0.01 | ~$0.05 |

Worst case under a flood at the default throttle (5 req/s sustained, ~13M
requests/month, max-size beacons): about $13 API Gateway + $6 Lambda +
$22 Firehose + $2 logs = **~$43/month**, and the alarm fires within the hour.

## Tests

```bash
node --test tests/collector.test.js
python -m pytest tests -q
terraform init -backend=false && terraform test   # mocked providers, no AWS calls
```

## License

MIT, see `LICENSE`.
