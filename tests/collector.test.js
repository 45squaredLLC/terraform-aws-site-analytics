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
