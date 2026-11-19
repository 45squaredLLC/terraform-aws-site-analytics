// Unit tests for the collector's pure logic. No dependencies:
//   node --test tests/collector.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const c = require('../collector/collector.js');

// Minimal element fakes: just what the collector reads.
function el(tag, opts = {}) {
  const node = {
    nodeType: 1,
    tagName: tag.toUpperCase(),
    id: opts.id || '',
    className: opts.cls || '',
    parentElement: null,
    children: [],
    attrs: opts.attrs || {},
    getAttribute(name) {
      if (name === 'id') return this.id || null;
      if (name === 'class') return this.className || null;
      return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null;
    },
  };
  return node;
}
function append(parent, ...kids) {
  for (const k of kids) {
    k.parentElement = parent;
    parent.children.push(k);
  }
  return parent;
}

test('privacy: GPC, DNT and automation send nothing', () => {
  assert.equal(c.privacyBlocked({ globalPrivacyControl: true }, {}), true);
  assert.equal(c.privacyBlocked({ doNotTrack: '1' }, {}), true);
  assert.equal(c.privacyBlocked({}, { doNotTrack: '1' }), true);
  assert.equal(c.privacyBlocked({ msDoNotTrack: '1' }, {}), true);
  assert.equal(c.privacyBlocked({ webdriver: true }, {}), true);
  assert.equal(c.privacyBlocked({ doNotTrack: '0', globalPrivacyControl: false }, {}), false);
  assert.equal(c.privacyBlocked({}, {}), false);
});

test('device class by viewport width', () => {
  assert.equal(c.deviceClass(390), 'm');
  assert.equal(c.deviceClass(820), 't');
  assert.equal(c.deviceClass(1440), 'd');
});

test('scroll depth is a clamped percent of the document', () => {
  assert.equal(c.depthPercent(0, 900, 3600), 25);
  assert.equal(c.depthPercent(2700, 900, 3600), 100);
  assert.equal(c.depthPercent(5000, 900, 3600), 100);
  assert.equal(c.depthPercent(0, 900, 0), 100);
});

test('referrer: host only, empty for same site or junk', () => {
  assert.equal(c.refHost('https://www.google.com/search?q=private', 'example.com'), 'www.google.com');
  assert.equal(c.refHost('https://example.com/other', 'example.com'), '');
  assert.equal(c.refHost('', 'example.com'), '');
  assert.equal(c.refHost('android-app://com.slack', 'example.com'), '');
});

test('random ids match the ingest id format', () => {
  const id = c.randomId('s', null);
  assert.match(id, /^[A-Za-z0-9_-]{8,40}$/);
  assert.notEqual(c.randomId('s', null), id);
});

test('interactive: tags, roles, handlers and ancestors', () => {
  const a = el('a');
  const span = el('span');
  append(a, span);
  assert.equal(c.isInteractive(span), true, 'inside a link');
  assert.equal(c.isInteractive(el('button')), true);
  assert.equal(c.isInteractive(el('div', { attrs: { role: 'button' } })), true);
  assert.equal(c.isInteractive(el('div', { attrs: { onclick: 'x()' } })), true);
  assert.equal(c.isInteractive(el('div', { attrs: { tabindex: '0' } })), true);
  assert.equal(c.isInteractive(el('div', { attrs: { tabindex: '-1' } })), false);
  const p = el('p');
  append(el('main'), p);
  assert.equal(c.isInteractive(p), false);
  assert.equal(c.isInteractive(el('img')), false);
});

test('selector: stops at a safe id, uses safe classes and nth-of-type', () => {
  const body = el('body');
  const main = el('main', { id: 'content' });
  const section = el('section', { cls: 'hero dark' });
  const d1 = el('div', { cls: 'card' });
  const d2 = el('div', { cls: 'card' });
  const img = el('img');
  append(body, main);
  append(main, section);
  append(section, d1, d2);
  append(d2, img);
  assert.equal(c.buildSelector(img), 'main#content > section.hero.dark > div.card:nth-of-type(2) > img');
});

test('selector: skips generated ids and classes and never uses text or attribute values', () => {
  const body = el('body');
  const div = el('div', { id: 'block-8f3a9c21d4', cls: 'css-1x2y3z4 x9a8b7c6d5e btn', attrs: { 'data-email': 'a@b.c' } });
  append(body, div);
  const sel = c.buildSelector(div);
  assert.equal(sel, 'div.btn');
  assert.doesNotMatch(sel, /@|8f3a9c21d4/);
});

test('selector output always passes the ingest selector check', () => {
  const body = el('body');
  let parent = body;
  for (let i = 0; i < 10; i++) {
    const n = el('div', { cls: 'wrapper-inner-container-element-' + 'x'.repeat(40) + ' second' });
    append(parent, n, el('div'));
    parent = n;
  }
  const sel = c.buildSelector(parent);
  assert.ok(sel.length <= 256);
  assert.match(sel, /^[A-Za-z0-9_ #.>:()-]{1,256}$/);
});

test('rage: 3 quick clicks in a small area, one event per burst', () => {
  const r = new c.RageDetector();
  assert.equal(r.add(100, 100, 0).rage, false);
  assert.equal(r.add(105, 98, 150).rage, false);
  const third = r.add(102, 101, 300);
  assert.equal(third.rage, true);
  assert.equal(third.n, 3);
  assert.equal(r.add(101, 101, 400).rage, false, 'same burst, no second event');
  // a fresh burst later counts again
  r.add(500, 500, 5000);
  r.add(500, 500, 5100);
  assert.equal(r.add(500, 500, 5200).rage, true);
});

test('rage: slow or spread-out clicks are not rage', () => {
  const r = new c.RageDetector();
  r.add(100, 100, 0);
  r.add(100, 100, 400);
  assert.equal(r.add(100, 100, 1100).rage, false, 'outside the 600 ms window');
  const s = new c.RageDetector();
  s.add(0, 0, 0);
  s.add(200, 0, 100);
  assert.equal(s.add(400, 0, 200).rage, false, 'too far apart');
});

test('payloads split under the byte cap and keep the envelope', () => {
  const env = { v: 1, k: 'pk_test_0001', sid: 's_abcdefgh', pv: 'p_abcdefgh', p: '/', r: '', dev: 'd', vw: 1, vh: 1, dw: 1, dh: 1 };
  const events = [];
  for (let i = 0; i < 120; i++) events.push({ t: 'click', seq: i, ts: 1, x: 1, y: 1, nx: 0.5, ny: 0.5, sel: 'main > div.x'.repeat(10), tag: 'div' });
  const out = c.buildPayloads(env, events, 4000);
  assert.ok(out.length > 1);
  let total = 0;
  for (const body of out) {
    assert.ok(body.length <= 4000, 'under cap');
    const parsed = JSON.parse(body);
    assert.equal(parsed.k, 'pk_test_0001');
    assert.ok(parsed.e.length <= 50);
    total += parsed.e.length;
  }
  assert.equal(total, 120);
  assert.deepEqual(c.buildPayloads(env, []), []);
});

test('session values survive in storage and fall back when storage throws', () => {
  const mem = {};
  const store = { getItem: (k) => mem[k] || null, setItem: (k, v) => { mem[k] = v; } };
  const a = c.sessionValue(store, 'sa_sid', () => 'first');
  const b = c.sessionValue(store, 'sa_sid', () => 'second');
  assert.equal(a, 'first');
  assert.equal(b, 'first');
  const broken = { getItem() { throw new Error('denied'); }, setItem() {} };
  assert.equal(c.sessionValue(broken, 'x', () => 'made'), 'made');
});

test('start() does nothing without a current script or under GPC', () => {
  const calls = [];
  const win = {
    navigator: { globalPrivacyControl: true, sendBeacon: () => calls.push('beacon') },
    addEventListener: () => calls.push('listen'),
  };
  const doc = {
    currentScript: { getAttribute: (n) => ({ 'data-endpoint': 'https://x/e', 'data-key': 'pk_test_0001' })[n] || null },
    addEventListener: () => calls.push('listen'),
  };
  c.start(win, doc);
  c.start({ navigator: {} }, { currentScript: null });
  assert.deepEqual(calls, []);
});

// ---------------------------------------------------------------- start() in a fake browser

// Just enough window/document for start(): timers and listeners are captured so a
// test can fire them, and beacons are parsed instead of sent.
function browser(opts = {}) {
  const listeners = { win: {}, doc: {} };
  const b = { beacons: [], timers: [], observer: null };
  const html = el('html');
  const body = el('body');
  append(html, body);
  Object.assign(html, { scrollWidth: 1440, clientWidth: 1440, scrollHeight: 3600, clientHeight: 900 });
  body.scrollHeight = 3600;
  const mem = {};
  const location = { pathname: opts.path || '/', hostname: 'example.com', href: '' };
  const go = (url) => {
    const [p, q] = String(url).split('?');
    location.pathname = p;
    location.href = 'https://example.com' + p + (q ? '?' + q : '');
  };
  go(location.pathname);
  b.win = {
    innerWidth: 1440,
    innerHeight: 900,
    scrollY: 0,
    location,
    navigator: {
      sendBeacon(url, payload) {
        b.beacons.push(JSON.parse(payload));
        return true;
      },
    },
    history: {
      calls: 0,
      pushState(state, title, url) {
        this.calls++;
        go(url);
        return 'pushed';
      },
      replaceState(state, title, url) {
        this.calls++;
        go(url);
      },
    },
    sessionStorage: { getItem: (k) => mem[k] || null, setItem: (k, v) => { mem[k] = v; } },
    getSelection: () => '',
    setTimeout: (fn, ms) => b.timers.push({ fn, ms }),
    setInterval: (fn) => { b.flush = fn; },
    addEventListener: (type, fn) => { listeners.win[type] = fn; },
    MutationObserver: class {
      constructor(cb) {
        this.cb = cb;
        b.observer = this;
      }
      observe(node, options) {
        this.options = options;
      }
    },
  };
  b.doc = {
    currentScript: { getAttribute: (n) => ({ 'data-endpoint': 'https://v.example.com/e', 'data-key': 'pk_test_0001' })[n] || null },
    documentElement: html,
    body,
    referrer: 'https://www.google.com/search?q=x',
    visibilityState: 'visible',
    addEventListener: (type, fn) => { listeners.doc[type] = fn; },
  };
  b.body = body;
  b.go = go;
  b.click = (target, x = 100, y = 300) => listeners.doc.click({ target, pageX: x, pageY: y });
  b.scrollTo = (y) => {
    b.win.scrollY = y;
    listeners.win.scroll();
  };
  b.hide = () => {
    b.doc.visibilityState = 'hidden';
    listeners.doc.visibilitychange();
  };
  b.popstate = (url) => {
    go(url);
    listeners.win.popstate();
  };
  b.mutate = (...targets) => b.observer.cb(targets.map((target) => ({ target })));
  b.runTimers = () => {
    const due = b.timers.splice(0);
    for (const t of due) t.fn();
  };
  b.events = () => b.beacons.flatMap((p) => p.e.map((e) => ({ ...e, p: p.p, pv: p.pv })));
  c.start(b.win, b.doc);
  return b;
}

test('multi-page site: one page view, path and referrer from the page, no history side effects', () => {
  const b = browser({ path: '/pricing/' });
  const link = el('a');
  append(b.body, link);
  b.click(link);
  // same path, new query string: still the same page view
  assert.equal(b.win.history.pushState({}, '', '/pricing/?tab=2'), 'pushed');
  b.win.history.replaceState({}, '', '/pricing/?tab=3');
  assert.equal(b.win.history.calls, 2, 'the original history functions still run');
  b.scrollTo(900);
  b.hide();
  assert.equal(b.beacons.length, 1);
  const p = b.beacons[0];
  assert.equal(p.p, '/pricing/');
  assert.equal(p.r, 'www.google.com');
  assert.deepEqual([p.vw, p.vh, p.dw, p.dh, p.dev], [1440, 900, 1440, 3600, 'd']);
  assert.deepEqual(p.e.map((e) => [e.t, e.seq]), [['pv', 0], ['click', 1], ['scroll', 2], ['scroll', 3], ['leave', 4]]);
  assert.equal(p.e[0].depth, 25);
  assert.equal(p.e[4].depth, 50);
});

test('single-page app: clicks are filed under the route they happened on', () => {
  const b = browser({ path: '/a' });
  const link = el('a');
  append(b.body, link);
  b.click(link);
  // the route changes before the 5 s flush: the click must still go out under /a
  b.win.history.pushState({}, '', '/b');
  assert.equal(b.beacons.length, 1);
  const first = b.beacons[0];
  assert.equal(first.p, '/a');
  assert.deepEqual(first.e.map((e) => e.t), ['pv', 'click', 'leave']);

  b.click(link);
  b.flush();
  const second = b.beacons[1];
  assert.equal(second.p, '/b');
  assert.notEqual(second.pv, first.pv, 'a new page view id per route');
  assert.match(second.pv, /^[A-Za-z0-9_-]{8,40}$/);
  assert.equal(second.sid, first.sid, 'same tab session');
  assert.equal(second.r, '', 'a route change has no external referrer');
  assert.deepEqual(second.e.map((e) => [e.t, e.seq]), [['pv', 0], ['click', 1]]);
});

test('single-page app: replaceState and back/forward also start a new page view', () => {
  const b = browser({ path: '/a' });
  b.win.history.replaceState({}, '', '/b');
  b.popstate('/a');
  b.hide();
  assert.deepEqual(b.beacons.map((p) => p.p), ['/a', '/b', '/a']);
  assert.equal(new Set(b.beacons.map((p) => p.pv)).size, 3);
});

test('single-page app: scroll depth and marks start again on the new route', () => {
  const b = browser({ path: '/a' });
  b.scrollTo(2700); // bottom of /a
  b.win.history.pushState({}, '', '/b');
  // the router has not moved the scroll position yet; it does before the settle timer
  b.win.scrollY = 0;
  b.runTimers();
  b.scrollTo(900);
  b.hide();
  const onB = b.events().filter((e) => e.p === '/b');
  assert.deepEqual(onB.map((e) => [e.t, e.depth]), [['pv', 25], ['scroll', 25], ['scroll', 50], ['leave', 50]]);
  const onA = b.events().filter((e) => e.p === '/a');
  assert.equal(onA[onA.length - 1].depth, 100, '/a keeps its own depth');
});

test('single-page app: a pending dead-click check does not leak into the next route', () => {
  const b = browser({ path: '/a' });
  const p = el('p');
  append(b.body, p);
  b.click(p);
  b.win.history.pushState({}, '', '/b');
  b.runTimers();
  b.hide();
  assert.equal(b.events().filter((e) => e.t === 'dead').length, 0);
});

test('related: same node, ancestor or descendant only', () => {
  const section = el('section');
  const card = el('div');
  const text = el('p');
  const other = el('div');
  append(section, card, other);
  append(card, text);
  assert.equal(c.related(text, text), true);
  assert.equal(c.related(section, text), true);
  assert.equal(c.related(text, section), true);
  assert.equal(c.related(other, text), false);
  assert.equal(c.related(null, text), false);
});

// A page with a text block and, elsewhere, a carousel that keeps changing.
function pageWithCarousel() {
  const b = browser();
  const main = el('main');
  const text = el('p');
  const strong = el('strong');
  const carousel = el('div', { cls: 'carousel' });
  const slide = el('div', { cls: 'slide' });
  append(b.body, main, carousel);
  append(main, text);
  append(text, strong);
  append(carousel, slide);
  const dead = () => {
    b.runTimers();
    b.hide();
    return b.events().filter((e) => e.t === 'dead');
  };
  return { b, main, text, strong, carousel, slide, dead };
}

test('dead click: nothing changed, so it is dead', () => {
  const { b, text, dead } = pageWithCarousel();
  b.click(text);
  const found = dead();
  assert.equal(found.length, 1);
  assert.equal(found[0].sel, 'main > p');
});

test('dead click: a running animation elsewhere does not hide it', () => {
  const { b, text, carousel, slide, dead } = pageWithCarousel();
  b.mutate(slide);
  b.click(text);
  // style/class changes on the slides and slides being swapped, all within the wait
  b.mutate(slide, carousel, slide);
  b.mutate(carousel);
  assert.equal(dead().length, 1);
});

test('dead click: a change on the element, inside it or on an ancestor is a reaction', () => {
  for (const pick of ['text', 'strong', 'main', 'body']) {
    const page = pageWithCarousel();
    page.b.click(page.text);
    page.b.mutate(page.slide, pick === 'body' ? page.b.body : page[pick]);
    assert.equal(page.dead().length, 0, pick);
  }
});

test('dead click: clicking inside the animated area still counts its changes as a reaction', () => {
  const { b, slide, carousel, dead } = pageWithCarousel();
  b.click(slide);
  b.mutate(carousel);
  assert.equal(dead().length, 0);
});

test('dead click: the element being removed, a scroll or a navigation is a reaction', () => {
  let page = pageWithCarousel();
  page.b.click(page.text);
  page.text.isConnected = false;
  assert.equal(page.dead().length, 0, 'removed');

  page = pageWithCarousel();
  page.b.click(page.text);
  page.b.win.scrollY = 400;
  assert.equal(page.dead().length, 0, 'scrolled');

  page = pageWithCarousel();
  page.b.click(page.text);
  page.b.go('/?opened=1');
  assert.equal(page.dead().length, 0, 'navigated');
});

test('dead click: never reported for interactive elements, and the observer stays document-wide', () => {
  const { b, main, dead } = pageWithCarousel();
  const button = el('button');
  append(main, button);
  b.click(button);
  assert.equal(dead().length, 0);
  assert.equal(b.observer.options.childList && b.observer.options.subtree, true);
  assert.equal(b.observer.options.characterData, false, 'page text is never observed');
});
