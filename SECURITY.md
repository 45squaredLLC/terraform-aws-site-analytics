# Security policy

## Reporting a vulnerability

Please report security issues privately via GitHub's private vulnerability
reporting on this repository rather than in a public issue. Expect an initial
response within a week.

## Scope and expectations

- **The ingest endpoint is public by design.** The site key is not a secret and
  `Origin` can be forged outside a browser; the API throttle is the cost
  ceiling and `alarm_topic_arn` tells you about floods. Lower the throttle or
  rotate a site key if you see abuse.
- **`create_reader` creates a long-lived IAM access key.** Its secret is in
  your Terraform state (and in SSM). Protect the state backend and rotate it.
- **No personal data by design:** no IP addresses, no User-Agent, no cookies,
  no input or page text. Paths have query strings and fragments removed.
