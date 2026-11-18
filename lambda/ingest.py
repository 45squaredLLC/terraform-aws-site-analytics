"""Ingest endpoint for the site-analytics collector.

API Gateway (HTTP API, payload v2) -> this function -> Amazon Data Firehose.

Everything that arrives here is untrusted. The function fails closed:

* POST only, body at most MAX_BODY_BYTES, JSON object only.
* The public site key must be in the SITES allowlist, and the request's Origin
  header must be one of that site's origins. (Origin can be forged by a
  non-browser client; this is routing and abuse filtering, not authentication.
  The data is low value and insert-only: nothing here reads or changes stored
  events.)
* Every field is validated against a fixed schema. Unknown fields are dropped;
  a malformed envelope or event rejects the whole batch.
* Known crawlers (by User-Agent) are accepted and discarded.

Privacy: the client IP and the User-Agent are never stored or logged. Logs
carry counts and reject reasons only, never payloads.
"""

from __future__ import annotations

import base64
import json
import os
import re
import time
from typing import Any

SCHEMA_VERSION = 1

EVENT_TYPES = frozenset({"pv", "click", "rage", "dead", "scroll", "leave"})
DEVICES = frozenset({"d", "t", "m"})

ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,40}$")
SITE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
HOST_RE = re.compile(r"^[a-z0-9.-]{1,253}$")
# The collector only emits tag names, #ids, .classes, :nth-of-type(n) and " > ".
SELECTOR_RE = re.compile(r"^[A-Za-z0-9_ #.>:()-]{1,256}$")
TAG_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
BOT_RE = re.compile(
    r"bot|crawl|spider|slurp|headless|lighthouse|pingdom|uptime|monitor|curl|wget|python|httpx|"
    r"go-http|java/|okhttp|facebookexternalhit|preview",
    re.IGNORECASE,
)

MAX_INT = 1_000_000
MAX_DUR_MS = 24 * 3600 * 1000


class Reject(Exception):
    def __init__(self, status: int, reason: str) -> None:
        super().__init__(reason)
        self.status = status
        self.reason = reason


def load_sites(raw: str) -> dict[str, dict[str, Any]]:
    """SITES_JSON: {"<public key>": {"site": "<site id>", "origins": ["https://..."]}}."""
    data = json.loads(raw or "{}")
    if not isinstance(data, dict):
        raise ValueError("SITES_JSON must be an object")
    sites: dict[str, dict[str, Any]] = {}
    for key, cfg in data.items():
        if not ID_RE.match(str(key)) or not isinstance(cfg, dict):
            raise ValueError("bad site entry")
        site = str(cfg.get("site", ""))
        origins = cfg.get("origins") or []
        if not SITE_ID_RE.match(site) or not isinstance(origins, list) or not origins:
            raise ValueError("bad site entry")
        sites[str(key)] = {"site": site, "origins": frozenset(str(o).lower() for o in origins)}
    return sites


# --------------------------------------------------------------------------- validation


def _int(value: Any, lo: int = 0, hi: int = MAX_INT) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise Reject(400, "not_a_number")
    if value != value:  # NaN
        raise Reject(400, "not_a_number")
    return int(max(lo, min(hi, value)))


def _ratio(value: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value:
        raise Reject(400, "not_a_number")
    return round(max(0.0, min(1.0, float(value))), 4)


def _id(value: Any) -> str:
    if not isinstance(value, str) or not ID_RE.match(value):
        raise Reject(400, "bad_id")
    return value


def clean_path(value: Any) -> str:
    """Path only: query string and fragment are cut (they can carry personal data)."""
    if not isinstance(value, str) or not value.startswith("/"):
        raise Reject(400, "bad_path")
    path = value.split("?", 1)[0].split("#", 1)[0]
    path = "".join(ch for ch in path if ch.isprintable())
    return path[:512] or "/"


def clean_ref(value: Any) -> str:
    """Referrer host only (the collector sends the host, never a full URL)."""
    if value in (None, ""):
        return ""
    if not isinstance(value, str):
        raise Reject(400, "bad_ref")
    host = value.lower()
    if not HOST_RE.match(host):
        raise Reject(400, "bad_ref")
    return host


def clean_event(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise Reject(400, "bad_event")
    t = raw.get("t")
    if t not in EVENT_TYPES:
        raise Reject(400, "bad_event_type")
    ev: dict[str, Any] = {
        "t": t,
        "seq": _int(raw.get("seq", 0)),
        "ts": _int(raw.get("ts", 0), 0, 10**13),
    }
    if t in ("click", "rage", "dead"):
        ev["x"] = _int(raw.get("x"))
        ev["y"] = _int(raw.get("y"))
        ev["nx"] = _ratio(raw.get("nx"))
        ev["ny"] = _ratio(raw.get("ny"))
        sel = raw.get("sel", "")
        if not isinstance(sel, str) or (sel and not SELECTOR_RE.match(sel)):
            raise Reject(400, "bad_selector")
        ev["sel"] = sel
        tag = raw.get("tag", "")
        if not isinstance(tag, str) or (tag and not TAG_RE.match(tag)):
            raise Reject(400, "bad_tag")
        ev["tag"] = tag
        if t == "rage":
            ev["n"] = _int(raw.get("n", 3), 3, 1000)
    if t in ("pv", "scroll", "leave"):
        ev["depth"] = _int(raw.get("depth", 0), 0, 100)
    if t == "leave":
        ev["dur"] = _int(raw.get("dur", 0), 0, MAX_DUR_MS)
    return ev


def parse_batch(
    body: str, origin: str, sites: dict[str, dict[str, Any]], max_events: int
) -> tuple[str, list[dict[str, Any]]]:
    """Validate one beacon. Returns (site id, flattened records)."""
    try:
        data = json.loads(body)
    except (ValueError, TypeError):
        raise Reject(400, "bad_json") from None
    if not isinstance(data, dict):
        raise Reject(400, "bad_json")
    if data.get("v") != SCHEMA_VERSION:
        raise Reject(400, "bad_version")
    cfg = sites.get(str(data.get("k", "")))
    if cfg is None:
        raise Reject(403, "unknown_key")
    if not origin or origin.lower() not in cfg["origins"]:
        raise Reject(403, "origin_not_allowed")

    events = data.get("e")
    if not isinstance(events, list) or not events:
        raise Reject(400, "no_events")
    if len(events) > max_events:
        raise Reject(413, "too_many_events")
    dev = data.get("dev")
    if dev not in DEVICES:
        raise Reject(400, "bad_device")

    base = {
        "v": SCHEMA_VERSION,
        "site": cfg["site"],
        "sid": _id(data.get("sid")),
        "pv": _id(data.get("pv")),
        "path": clean_path(data.get("p")),
        "ref": clean_ref(data.get("r")),
        "dev": dev,
        "vw": _int(data.get("vw")),
        "vh": _int(data.get("vh")),
        "dw": _int(data.get("dw")),
        "dh": _int(data.get("dh")),
        "rts": int(time.time() * 1000),
    }
    return cfg["site"], [{**base, **clean_event(ev)} for ev in events]


# --------------------------------------------------------------------------- handler

_SITES: dict[str, dict[str, Any]] | None = None
_FIREHOSE: Any = None


def _sites() -> dict[str, dict[str, Any]]:
    global _SITES
    if _SITES is None:
        _SITES = load_sites(os.environ.get("SITES_JSON", "{}"))
    return _SITES


def _firehose() -> Any:
    global _FIREHOSE
    if _FIREHOSE is None:
        import boto3

        _FIREHOSE = boto3.client("firehose", region_name=os.environ.get("AWS_REGION", "us-east-1"))
    return _FIREHOSE


def put_records(client: Any, stream: str, records: list[dict[str, Any]]) -> int:
    """One Firehose record per beacon: the events as newline-delimited JSON.

    Firehose bills each record rounded up to 5 KB, so one record per beacon
    (at most MAX_BODY_BYTES) instead of one per event cuts ingest cost by up to
    ~50x; the stream's RecordDeAggregation processor splits the lines again
    before partitioning and Parquet conversion. Retries once. Returns events lost.
    """
    data = "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in records).encode()
    for _attempt in range(2):
        try:
            client.put_record(DeliveryStreamName=stream, Record={"Data": data})
            return 0
        except Exception as exc:  # noqa: BLE001 - boto3 raises many types; log the class only
            _log(result="put_failed", error=type(exc).__name__)
    return len(records)


def _response(status: int) -> dict[str, Any]:
    return {"statusCode": status, "headers": {"Cache-Control": "no-store"}, "body": ""}


def _log(**fields: Any) -> None:
    print(json.dumps(fields, separators=(",", ":")))


def handler(event: dict[str, Any], _context: Any = None) -> dict[str, Any]:
    max_body = int(os.environ.get("MAX_BODY_BYTES", "16384"))
    max_events = int(os.environ.get("MAX_EVENTS", "60"))
    try:
        method = event.get("requestContext", {}).get("http", {}).get("method", "")
        if method != "POST":
            raise Reject(405, "method")
        headers = {str(k).lower(): str(v) for k, v in (event.get("headers") or {}).items()}
        raw = event.get("body") or ""
        if len(raw) > max_body * 2:  # cheap guard before decoding
            raise Reject(413, "too_large")
        if event.get("isBase64Encoded"):
            try:
                raw = base64.b64decode(raw).decode("utf-8")
            except (ValueError, UnicodeDecodeError):
                raise Reject(400, "bad_encoding") from None
        if len(raw.encode("utf-8")) > max_body:
            raise Reject(413, "too_large")
        if BOT_RE.search(headers.get("user-agent", "")) or not headers.get("user-agent"):
            _log(result="bot_dropped")
            return _response(204)
        site, records = parse_batch(raw, headers.get("origin", ""), _sites(), max_events)
    except Reject as exc:
        _log(result="rejected", status=exc.status, reason=exc.reason)
        return _response(exc.status)

    lost = put_records(_firehose(), os.environ["STREAM_NAME"], records)
    _log(result="accepted", site=site, events=len(records), lost=lost)
    return _response(204 if not lost else 503)
