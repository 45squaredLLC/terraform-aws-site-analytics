/*!
 * site-analytics collector v1 (MIT). Cookieless, first-party visitor analytics:
 * clicks, scroll depth, rage clicks, dead clicks and time on page.
 *
 *   <script defer src="/path/to/collector.js"
 *           data-endpoint="https://<api>/e" data-key="<public site key>"
 *           data-sample="1"></script>
 *
 * Never captures keystrokes, input values or any text on the page. Sends nothing
 * when Global Privacy Control or Do Not Track is on, or for automated browsers.
 * No cookies and no cross-site id: one random id per tab in sessionStorage.
 */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = api;
  } else if (root && root.document) {
    api.start(root, root.document);
  }
})(typeof window !== 'undefined' ? window : this, function () {
  'use strict';

  var VERSION = 1;
  var RAGE_CLICKS = 3;
  var RAGE_WINDOW_MS = 600;
  var RAGE_RADIUS_PX = 30;
  var DEAD_WAIT_MS = 1000;
  var FLUSH_MS = 5000;
  var MAX_QUEUE = 20;
  var MAX_CLICKS_PER_VIEW = 300;
  var MAX_BYTES = 15000;
  var SCROLL_MARKS = [25, 50, 75, 90, 100];

  var INTERACTIVE_TAGS = {
    a: 1, button: 1, input: 1, select: 1, textarea: 1, label: 1, summary: 1,
    details: 1, option: 1, video: 1, audio: 1, iframe: 1
  };
  var INTERACTIVE_ROLES = {
    button: 1, link: 1, checkbox: 1, radio: 1, tab: 1, menuitem: 1, switch: 1,
    option: 1, combobox: 1, textbox: 1, slider: 1
  };
  var SAFE_NAME = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
  // ids/classes that look generated (CSS-in-JS, hashes, numbers) make unstable selectors
  var GENERATED = /^(css|sc|jsx|svelte|emotion)-|\d{4,}|[0-9a-f]{8,}|\d\D*\d\D*\d/i;

  /** True when the visitor asked not to be tracked, or the browser is automated. */
  function privacyBlocked(nav, win) {
    nav = nav || {};
    win = win || {};
    if (nav.globalPrivacyControl === true) return true;
    var dnt = nav.doNotTrack || win.doNotTrack || nav.msDoNotTrack;
    if (dnt === '1' || dnt === 'yes' || dnt === 1) return true;
    if (nav.webdriver === true) return true;
    return false;
  }

  function deviceClass(width) {
    if (width < 768) return 'm';
    if (width < 1100) return 't';
    return 'd';
  }

  /** Deepest point seen, as a percent of the document height (0-100). */
  function depthPercent(scrollY, viewportH, docH) {
    if (!docH || docH <= 0) return 100;
    var pct = Math.round(((scrollY + viewportH) / docH) * 100);
    return Math.max(0, Math.min(100, pct));
  }

  /** Referrer host, or '' for none / same site. Never the full URL. */
  function refHost(referrer, ownHost) {
    if (!referrer) return '';
    var m = /^https?:\/\/([^/:?#]+)/i.exec(referrer);
    if (!m) return '';
    var host = m[1].toLowerCase();
    if (host === String(ownHost || '').toLowerCase()) return '';
    return /^[a-z0-9.-]{1,253}$/.test(host) ? host : '';
  }

  function randomId(prefix, cryptoObj) {
    var bytes = [];
    var i;
    if (cryptoObj && cryptoObj.getRandomValues) {
      var arr = new Uint8Array(12);
      cryptoObj.getRandomValues(arr);
      for (i = 0; i < arr.length; i++) bytes.push(arr[i]);
    } else {
      for (i = 0; i < 12; i++) bytes.push(Math.floor(Math.random() * 256));
    }
    var abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    var out = prefix;
    for (i = 0; i < bytes.length; i++) out += abc.charAt(bytes[i] % abc.length);
    return out;
  }

  function lower(s) {
    return String(s || '').toLowerCase();
  }

  function attr(el, name) {
    return el && el.getAttribute ? el.getAttribute(name) : null;
  }

  /** The element or an ancestor is something a person expects to react to a click. */
  function isInteractive(el) {
    var depth = 0;
    while (el && depth < 12) {
      var tag = lower(el.tagName);
      if (INTERACTIVE_TAGS[tag]) return true;
      var role = lower(attr(el, 'role'));
      if (role && INTERACTIVE_ROLES[role]) return true;
      if (attr(el, 'onclick') !== null) return true;
      var tab = attr(el, 'tabindex');
      if (tab !== null && tab !== '-1') return true;
      if (attr(el, 'contenteditable') === 'true') return true;
      el = el.parentElement;
      depth++;
    }
    return false;
  }

  function classList(el) {
    var raw = typeof el.className === 'string' ? el.className : attr(el, 'class') || '';
    return raw.split(/\s+/).filter(function (c) {
      return c && SAFE_NAME.test(c) && !GENERATED.test(c);
    });
  }

  function nthOfType(el) {
    var parent = el.parentElement;
    if (!parent || !parent.children) return 0;
    var tag = lower(el.tagName);
    var same = 0;
    var index = 0;
    for (var i = 0; i < parent.children.length; i++) {
      var sib = parent.children[i];
      if (lower(sib.tagName) === tag) {
        same++;
        if (sib === el) index = same;
      }
    }
    return same > 1 ? index : 0;
  }

  /**
   * A stable CSS selector built only from tag names, safe ids, up to two safe
   * classes and :nth-of-type. Stops at the first safe id. Never uses text,
   * attribute values or anything a visitor typed.
   */
  function buildSelector(el, maxParts) {
    maxParts = maxParts || 5;
    var parts = [];
    while (el && el.tagName && parts.length < maxParts) {
      var tag = lower(el.tagName);
      if (tag === 'html' || tag === 'body') break;
      var id = el.id || attr(el, 'id');
      if (id && SAFE_NAME.test(id) && !GENERATED.test(id)) {
        parts.unshift(tag + '#' + id);
        break;
      }
      var part = tag;
      var classes = classList(el).slice(0, 2);
      if (classes.length) part += '.' + classes.join('.');
      var nth = nthOfType(el);
      if (nth) part += ':nth-of-type(' + nth + ')';
      parts.unshift(part);
      el = el.parentElement;
    }
    var sel = parts.join(' > ');
    return sel.length > 256 ? sel.slice(sel.length - 256).replace(/^[^ ]* > /, '') : sel;
  }

  /** Rage = RAGE_CLICKS+ clicks within RAGE_WINDOW_MS inside RAGE_RADIUS_PX. */
  function RageDetector() {
    this.clicks = [];
    this.active = false;
  }
  RageDetector.prototype.add = function (x, y, ts) {
    this.clicks = this.clicks.filter(function (c) {
      return ts - c.ts <= RAGE_WINDOW_MS;
    });
    var near = this.clicks.filter(function (c) {
      return Math.abs(c.x - x) <= RAGE_RADIUS_PX && Math.abs(c.y - y) <= RAGE_RADIUS_PX;
    });
    this.clicks.push({ x: x, y: y, ts: ts });
    var n = near.length + 1;
    if (n >= RAGE_CLICKS) {
      // one rage event per burst; its count keeps rising until the burst ends
      var first = !this.active;
      this.active = true;
      return { rage: first, n: n };
    }
    this.active = false;
    return { rage: false, n: n };
  };

  /** Split a list of events into payloads that each stay under MAX_BYTES. */
  function buildPayloads(envelope, events, maxBytes) {
    maxBytes = maxBytes || MAX_BYTES;
    var out = [];
    var batch = [];
    function emit() {
      if (!batch.length) return;
      var body = {};
      for (var k in envelope) if (Object.prototype.hasOwnProperty.call(envelope, k)) body[k] = envelope[k];
      body.e = batch;
      out.push(JSON.stringify(body));
      batch = [];
    }
    var base = JSON.stringify(envelope).length + 8;
    var size = base;
    for (var i = 0; i < events.length; i++) {
      var len = JSON.stringify(events[i]).length + 1;
      if (batch.length && (size + len > maxBytes || batch.length >= 50)) {
        emit();
        size = base;
      }
      batch.push(events[i]);
      size += len;
    }
    emit();
    return out;
  }

  function sessionValue(storage, key, make) {
    try {
      var v = storage.getItem(key);
      if (!v) {
        v = make();
        storage.setItem(key, v);
      }
      return v;
    } catch (e) {
      return make();
    }
  }

  // ------------------------------------------------------------------ browser wiring

  function start(win, doc) {
    var script = doc.currentScript;
    if (!script || win.__siteAnalytics) return;
    win.__siteAnalytics = true;
    var endpoint = attr(script, 'data-endpoint');
    var key = attr(script, 'data-key');
    var sample = parseFloat(attr(script, 'data-sample') || '1');
    if (!endpoint || !key || privacyBlocked(win.navigator, win)) return;

    var storage = null;
    try {
      storage = win.sessionStorage;
    } catch (e) {
      storage = null;
    }
    var store = storage || { getItem: function () { return null; }, setItem: function () {} };
    // sampling is decided once per tab session, so a session is all in or all out
    var inSample = sessionValue(store, 'sa_in', function () {
      return Math.random() < (isNaN(sample) ? 1 : sample) ? '1' : '0';
    });
    if (inSample !== '1') return;

    var sid = sessionValue(store, 'sa_sid', function () {
      return randomId('s', win.crypto);
    });
    var pv = randomId('p', win.crypto);
    var seq = 0;
    var queue = [];
    var clicks = 0;
    var maxDepth = 0;
    var marks = {};
    var visibleMs = 0;
    var visibleSince = doc.visibilityState === 'visible' ? Date.now() : 0;
    var lastChange = 0;
    var rage = new RageDetector();
    var de = doc.documentElement;

    function docW() {
      return Math.max(de.scrollWidth, de.clientWidth, 1);
    }
    function docH() {
      return Math.max(de.scrollHeight, doc.body ? doc.body.scrollHeight : 0, 1);
    }
    function envelope() {
      var vw = win.innerWidth || de.clientWidth;
      return {
        v: VERSION, k: key, sid: sid, pv: pv,
        p: win.location.pathname,
        r: refHost(doc.referrer, win.location.hostname),
        dev: deviceClass(vw),
        vw: vw, vh: win.innerHeight || de.clientHeight, dw: docW(), dh: docH()
      };
    }
    function push(ev) {
      ev.seq = seq++;
      ev.ts = Date.now();
      queue.push(ev);
      if (queue.length >= MAX_QUEUE) flush();
    }
    function send(body) {
      try {
        if (win.navigator.sendBeacon && win.navigator.sendBeacon(endpoint, body)) return;
      } catch (e) { /* fall through */ }
      try {
        win.fetch(endpoint, {
          method: 'POST', body: body, keepalive: true, mode: 'no-cors', credentials: 'omit',
          headers: { 'Content-Type': 'text/plain' }
        });
      } catch (e) { /* analytics never breaks the page */ }
    }
    function flush() {
      if (!queue.length) return;
      var payloads = buildPayloads(envelope(), queue);
      queue = [];
      for (var i = 0; i < payloads.length; i++) send(payloads[i]);
    }
    function depthNow() {
      return depthPercent(win.scrollY || de.scrollTop || 0, win.innerHeight || de.clientHeight, docH());
    }
    function onScroll() {
      var d = depthNow();
      if (d <= maxDepth) return;
      maxDepth = d;
      for (var i = 0; i < SCROLL_MARKS.length; i++) {
        var m = SCROLL_MARKS[i];
        if (d >= m && !marks[m]) {
          marks[m] = 1;
          push({ t: 'scroll', depth: m });
        }
      }
    }
    function point(e, t, extra) {
      var target = e.target && e.target.nodeType === 1 ? e.target : e.target && e.target.parentElement;
      var ev = {
        t: t,
        x: Math.round(e.pageX), y: Math.round(e.pageY),
        nx: Math.round((e.pageX / docW()) * 10000) / 10000,
        ny: Math.round((e.pageY / docH()) * 10000) / 10000,
        sel: target ? buildSelector(target) : '',
        tag: target ? lower(target.tagName) : ''
      };
      if (extra) for (var k in extra) ev[k] = extra[k];
      return ev;
    }
    function onClick(e) {
      if (clicks++ >= MAX_CLICKS_PER_VIEW) return;
      var now = Date.now();
      push(point(e, 'click'));
      var r = rage.add(e.pageX, e.pageY, now);
      if (r.rage) push(point(e, 'rage', { n: r.n }));
      var target = e.target && e.target.nodeType === 1 ? e.target : null;
      if (!target || isInteractive(target)) return;
      var href = win.location.href;
      var scrolled = win.scrollY;
      var dead = point(e, 'dead');
      win.setTimeout(function () {
        var sel = win.getSelection ? String(win.getSelection()) : '';
        if (lastChange >= now || win.location.href !== href || win.scrollY !== scrolled || sel) return;
        push(dead);
      }, DEAD_WAIT_MS);
    }
    function onHide() {
      if (visibleSince) {
        visibleMs += Date.now() - visibleSince;
        visibleSince = 0;
      }
      onScroll();
      push({ t: 'leave', depth: maxDepth, dur: visibleMs });
      flush();
    }

    if (win.MutationObserver) {
      new win.MutationObserver(function () {
        lastChange = Date.now();
      }).observe(de, { childList: true, subtree: true, attributes: true, characterData: false });
    }
    maxDepth = depthNow();
    push({ t: 'pv', depth: maxDepth });
    doc.addEventListener('click', onClick, { capture: true, passive: true });
    win.addEventListener('scroll', onScroll, { passive: true });
    doc.addEventListener('visibilitychange', function () {
      if (doc.visibilityState === 'hidden') onHide();
      else visibleSince = Date.now();
    });
    win.addEventListener('pagehide', function () {
      if (visibleSince) onHide();
    });
    win.setInterval(flush, FLUSH_MS);
  }

  return {
    VERSION: VERSION,
    privacyBlocked: privacyBlocked,
    deviceClass: deviceClass,
    depthPercent: depthPercent,
    refHost: refHost,
    randomId: randomId,
    isInteractive: isInteractive,
    buildSelector: buildSelector,
    RageDetector: RageDetector,
    buildPayloads: buildPayloads,
    sessionValue: sessionValue,
    start: start
  };
});
