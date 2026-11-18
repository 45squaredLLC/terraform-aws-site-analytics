"""Tests for ingest.py. Stdlib only; run with either of

python3 -m pytest tests
python3 -m unittest discover -s tests -p "test_*.py"
"""

from __future__ import annotations

import base64
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda"))

import ingest  # noqa: E402

KEY = "pk_test_0001"
ORIGIN = "https://example.com"
SITES_JSON = json.dumps(
    {KEY: {"site": "example-com", "origins": [ORIGIN, "https://www.example.com"]}}
)
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130 Safari/537.36"


def batch(**over):
    body = {
        "v": 1,
        "k": KEY,
        "sid": "s_abcdefgh",
        "pv": "p_abcdefgh",
        "p": "/pricing/",
        "r": "google.com",
        "dev": "d",
        "vw": 1440,
        "vh": 900,
        "dw": 1440,
        "dh": 4200,
        "e": [
            {"t": "pv", "seq": 0, "ts": 1700000000000, "depth": 21},
            {
                "t": "click",
                "seq": 1,
                "ts": 1700000001000,
                "x": 100,
                "y": 300,
                "nx": 0.07,
                "ny": 0.071,
                "sel": "main > div.hero > a#cta",
                "tag": "a",
            },
            {
                "t": "rage",
                "seq": 2,
                "ts": 1700000002000,
                "x": 5,
                "y": 5,
                "nx": 0.1,
                "ny": 0.1,
                "sel": "div.card:nth-of-type(2)",
                "tag": "div",
                "n": 4,
            },
            {"t": "leave", "seq": 3, "ts": 1700000009000, "depth": 80, "dur": 8000},
        ],
    }
    body.update(over)
    return body


class FakeFirehose:
    def __init__(self, fail_first=0):
        self.calls = []
        self.fail_first = fail_first

    def put_record(self, DeliveryStreamName, Record):  # noqa: N803 - boto3 casing
        self.calls.append((DeliveryStreamName, Record))
        if self.fail_first:
            self.fail_first -= 1
            raise RuntimeError("ServiceUnavailable")
        return {"RecordId": "x"}


def http_event(body, origin=ORIGIN, method="POST", ua=UA, b64=False):
    raw = json.dumps(body) if not isinstance(body, str) else body
    if b64:
        raw = base64.b64encode(raw.encode()).decode()
    headers = {"content-type": "text/plain;charset=UTF-8"}
    if origin is not None:
        headers["origin"] = origin
    if ua is not None:
        headers["user-agent"] = ua
    return {
        "requestContext": {"http": {"method": method, "sourceIp": "203.0.113.9"}},
        "headers": headers,
        "body": raw,
        "isBase64Encoded": b64,
    }


class ParseBatchTests(unittest.TestCase):
    def setUp(self):
        self.sites = ingest.load_sites(SITES_JSON)

    def test_valid_batch_flattens_envelope_into_each_record(self):
        site, recs = ingest.parse_batch(json.dumps(batch()), ORIGIN, self.sites, 60)
        self.assertEqual(site, "example-com")
        self.assertEqual(len(recs), 4)
        for r in recs:
            self.assertEqual(r["site"], "example-com")
            self.assertEqual(r["path"], "/pricing/")
            self.assertIn("rts", r)
        self.assertEqual(recs[1]["sel"], "main > div.hero > a#cta")
        self.assertEqual(recs[2]["n"], 4)
        self.assertEqual(recs[3]["dur"], 8000)

    def test_unknown_key_is_403(self):
        with self.assertRaises(ingest.Reject) as cm:
            ingest.parse_batch(json.dumps(batch(k="pk_other_999")), ORIGIN, self.sites, 60)
        self.assertEqual(cm.exception.status, 403)

    def test_origin_must_match_the_key(self):
        for origin in ("", "https://evil.example", "http://example.com"):
            with self.assertRaises(ingest.Reject) as cm:
                ingest.parse_batch(json.dumps(batch()), origin, self.sites, 60)
            self.assertEqual(cm.exception.status, 403, origin)

    def test_unknown_fields_are_dropped(self):
        b = batch()
        b["email"] = "x@y.z"
        b["e"][1]["text"] = "secret typed text"
        b["e"][1]["value"] = "hunter2"
        _, recs = ingest.parse_batch(json.dumps(b), ORIGIN, self.sites, 60)
        for r in recs:
            self.assertNotIn("email", r)
            self.assertNotIn("text", r)
            self.assertNotIn("value", r)

    def test_query_string_and_fragment_are_cut_from_path(self):
        _, recs = ingest.parse_batch(
            json.dumps(batch(p="/thanks/?email=a@b.c&token=1#x")), ORIGIN, self.sites, 60
        )
        self.assertEqual(recs[0]["path"], "/thanks/")

    def test_rejects(self):
        cases = {
            "bad_version": batch(v=2),
            "bad_event_type": batch(e=[{"t": "keypress"}]),
            "bad_selector": batch(
                e=[
                    {
                        "t": "click",
                        "x": 1,
                        "y": 1,
                        "nx": 0,
                        "ny": 0,
                        "sel": "a[href='javascript:alert(1)']",
                    }
                ]
            ),
            "bad_id": batch(sid="short"),
            "bad_path": batch(p="https://example.com/"),
            "bad_ref": batch(r="https://google.com/search?q=me"),
            "bad_device": batch(dev="phone"),
            "no_events": batch(e=[]),
            "not_a_number": batch(vw="1440"),
        }
        for reason, b in cases.items():
            with self.assertRaises(ingest.Reject, msg=reason) as cm:
                ingest.parse_batch(json.dumps(b), ORIGIN, self.sites, 60)
            self.assertEqual(cm.exception.reason, reason)

    def test_too_many_events_is_413(self):
        b = batch(e=[{"t": "scroll", "depth": 10}] * 61)
        with self.assertRaises(ingest.Reject) as cm:
            ingest.parse_batch(json.dumps(b), ORIGIN, self.sites, 60)
        self.assertEqual(cm.exception.status, 413)

    def test_numbers_are_clamped(self):
        b = batch(
            e=[
                {"t": "click", "x": -5, "y": 10**12, "nx": 7, "ny": -1, "sel": "a", "tag": "a"},
                {"t": "scroll", "depth": 500},
            ]
        )
        _, recs = ingest.parse_batch(json.dumps(b), ORIGIN, self.sites, 60)
        self.assertEqual((recs[0]["x"], recs[0]["y"]), (0, ingest.MAX_INT))
        self.assertEqual((recs[0]["nx"], recs[0]["ny"]), (1.0, 0.0))
        self.assertEqual(recs[1]["depth"], 100)

    def test_booleans_are_not_numbers(self):
        with self.assertRaises(ingest.Reject):
            ingest.parse_batch(json.dumps(batch(vw=True)), ORIGIN, self.sites, 60)


class LoadSitesTests(unittest.TestCase):
    def test_bad_config_raises(self):
        for raw in (
            '{"k": {"site": "x", "origins": []}}',
            '{"pk_test_0001": {"site": "Bad Id", "origins": ["https://a"]}}',
            "[]",
        ):
            with self.assertRaises(ValueError):
                ingest.load_sites(raw)


class HandlerTests(unittest.TestCase):
    def setUp(self):
        os.environ["SITES_JSON"] = SITES_JSON
        os.environ["STREAM_NAME"] = "test-stream"
        ingest._SITES = None
        self.fh = FakeFirehose()
        ingest._FIREHOSE = self.fh

    def test_accepts_and_writes_one_ndjson_record_per_beacon(self):
        resp = ingest.handler(http_event(batch()))
        self.assertEqual(resp["statusCode"], 204)
        self.assertEqual(len(self.fh.calls), 1)
        stream, record = self.fh.calls[0]
        self.assertEqual(stream, "test-stream")
        data = record["Data"].decode()
        self.assertTrue(data.endswith("\n"))
        lines = [json.loads(line) for line in data.splitlines()]
        self.assertEqual([r["t"] for r in lines], ["pv", "click", "rage", "leave"])
        self.assertTrue(all(r["site"] == "example-com" for r in lines))
        self.assertNotIn("203.0.113.9", data)
        self.assertNotIn("Mozilla", data)

    def test_base64_body(self):
        self.assertEqual(ingest.handler(http_event(batch(), b64=True))["statusCode"], 204)

    def test_get_is_405(self):
        self.assertEqual(ingest.handler(http_event(batch(), method="GET"))["statusCode"], 405)
        self.assertEqual(self.fh.calls, [])

    def test_oversized_body_is_413(self):
        b = batch()
        b["pad"] = "x" * 20000
        self.assertEqual(ingest.handler(http_event(b))["statusCode"], 413)
        self.assertEqual(self.fh.calls, [])

    def test_missing_origin_is_403(self):
        self.assertEqual(ingest.handler(http_event(batch(), origin=None))["statusCode"], 403)

    def test_bots_are_dropped_quietly(self):
        for ua in ("Googlebot/2.1", "Mozilla/5.0 HeadlessChrome/120", "curl/8.0", None):
            self.assertEqual(ingest.handler(http_event(batch(), ua=ua))["statusCode"], 204)
        self.assertEqual(self.fh.calls, [])

    def test_failed_put_retries_once(self):
        self.fh.fail_first = 1
        self.assertEqual(ingest.handler(http_event(batch()))["statusCode"], 204)
        self.assertEqual(len(self.fh.calls), 2)

    def test_put_failing_twice_is_503(self):
        self.fh.fail_first = 2
        self.assertEqual(ingest.handler(http_event(batch()))["statusCode"], 503)

    def test_garbage_body_is_400(self):
        self.assertEqual(ingest.handler(http_event("not json"))["statusCode"], 400)


if __name__ == "__main__":
    unittest.main()
