// **QUOTE-REPLY AND EDIT, THE SCRIPT'S RULES, IN NODE** (js/quote.js), run
// by verify: with a stubbed page (its keys, its feed, its compose box, its
// fetch and its clock), q and e do nothing and keep the key with nothing
// selected, while a send is out, or (e) on another's message; asked, the
// answer goes in the box (q at the cursor, e as the whole text with its
// caret); no answer in 3 s is the host-down modal and a later answer is
// dropped; a refusal is said, but never over a send's "Sending…"; and an
// "Edited in" link selects the edit, with no jump. One line a check, PASS
// or FAIL, then exit 1 when any failed.
//
//   node tools/quote_test.js
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'js', 'quote.js'), 'utf8');

// A fresh page: what the script was given, and what it did.
function page() {
  const did = { fetched: [], said: [], alerts: [], inserted: [], set: [], opened: 0, revealed: [] };
  const keys = {};
  let click = null;
  const elements = {};
  const timers = [];
  const answers = [];
  const document = {
    head: { appendChild: () => {} },
    body: { dataset: { quote: '/t/quote', edit: '/t/edit' } },
    createElement: () => ({}),
    getElementById: (id) => (id === 'chat-bubbles' ? { addEventListener: (t, fn) => { if (t === 'click') click = fn; } } : elements[id] || null),
  };
  const state = { selected: null, pending: false };
  const window = {};
  const ctx = {
    window, document,
    Keys: { register: (e) => { keys[e.key] = e; } },
    Feed: { selected: () => state.selected, reveal: (b) => did.revealed.push(b) },
    Compose: {
      isPending: () => state.pending, open: () => { did.opened++; },
      insertAtCursor: (t) => did.inserted.push(t), setMarkdown: (t, c) => did.set.push([t, c]),
      say: (l) => did.said.push(l), alert: (m) => did.alerts.push(m), hostDownMs: 3000,
    },
    fetch: (url) => { did.fetched.push(url); return new Promise((resolve, reject) => answers.push({ resolve, reject })); },
    setTimeout: (fn, ms) => { timers.push({ fn, ms, live: true }); return timers.length - 1; },
    clearTimeout: (i) => { if (timers[i]) timers[i].live = false; },
  };
  vm.runInNewContext(source, ctx);
  const ok = (json) => answers.shift().resolve({ ok: true, json: () => Promise.resolve(json) });
  const refused = (why) => answers.shift().resolve({ ok: false, status: 403, text: () => Promise.resolve(why) });
  const lost = () => answers.shift().reject(new Error('Failed to fetch'));
  const tick = () => timers.filter((t) => t.live).forEach((t) => { t.live = false; t.fn(); });
  const settle = () => new Promise((r) => setImmediate(r));
  return { keys, did, state, elements, ok, refused, lost, tick, settle, click: (e) => click(e) };
}

const bubble = (id, mine) => ({ dataset: { id: String(id) }, classList: { contains: (c) => c === 'mine' && mine } });

let failed = 0;
function check(ok, what) {
  console.log((ok ? 'PASS' : 'FAIL') + '  quote.js: ' + what);
  if (!ok) failed++;
}

(async () => {
  {
    const p = page();
    check(['q', 'r', '>', 'e'].every((k) => p.keys[k]) && !p.keys.q.hidden && p.keys.r.hidden && p.keys['>'].hidden && !p.keys.e.hidden, 'q and e in the panel, r and > hidden aliases');
    check(p.keys.q.run() === false && p.did.fetched.length === 0, 'q with nothing selected keeps the key, asks nothing');
    p.state.selected = bubble(3, true);
    p.state.pending = true;
    check(p.keys.q.run() === false && p.keys.e.run() === false && p.did.fetched.length === 0, 'q and e while a send is out keep the key');
    p.state.pending = false;
    p.state.selected = bubble(4, false);
    check(p.keys.e.run() === false && p.did.fetched.length === 0, "e on another's message keeps the key");
  }
  {
    const p = page();
    p.state.selected = bubble(3, false);
    check(p.keys.q.run() !== false && p.did.fetched[0] === '/t/quote?n=3' && p.did.revealed[0] === p.state.selected, 'q asks for the selected message, and selects it');
    p.ok({ text: 'In MSG_T_3 you said:\n' });
    await p.settle();
    check(p.did.opened === 1 && p.did.inserted[0] === 'In MSG_T_3 you said:\n' && p.did.set.length === 0, 'the quote goes in at the cursor, compose opened');
  }
  {
    const p = page();
    p.state.selected = bubble(5, true);
    p.keys.e.run();
    p.ok({ text: 'Edit of MSG_T_5\n\nold', caret: 17 });
    await p.settle();
    check(p.did.fetched[0] === '/t/edit?n=5' && JSON.stringify(p.did.set[0]) === JSON.stringify(['Edit of MSG_T_5\n\nold', 17]), 'the edit is the whole text, its caret given');
  }
  {
    const p = page();
    p.state.selected = bubble(3, false);
    p.keys.q.run();
    p.tick();
    check(p.did.alerts[0] === 'The host may be down. Please retry.', 'no answer in 3 s: the host-down modal');
    p.ok({ text: 'late' });
    await p.settle();
    check(p.did.inserted.length === 0 && p.did.opened === 0, 'an answer after the modal is dropped');
  }
  {
    const p = page();
    p.state.selected = bubble(3, true);
    p.keys.e.run();
    p.refused('only its author edits a message\n');
    await p.settle();
    check(p.did.said[0] === 'Could not load that message: only its author edits a message' && p.did.alerts.length === 0, 'a refusal is said in the compose status');
    p.tick();
    check(p.did.alerts.length === 0, 'and its timer is gone');
  }
  {
    const p = page();
    p.state.selected = bubble(3, false);
    p.keys.q.run();
    p.state.pending = true;
    p.lost();
    await p.settle();
    check(p.did.said.length === 0 && p.did.inserted.length === 0, 'a lost answer while a send is out says nothing over "Sending…"');
  }
  {
    const p = page();
    const edit = { id: 'msg-9' };
    p.elements['msg-9'] = edit;
    let prevented = false;
    const link = { getAttribute: () => '#msg-9' };
    p.click({ preventDefault: () => { prevented = true; }, target: { closest: (sel) => (sel === '.chat-edited-note a.msg-ref' ? link : null) } });
    check(prevented && p.did.revealed[0] === edit, '"Edited in" selects the edit, with no jump');
  }
  process.exit(failed === 0 ? 0 : 1);
})();
