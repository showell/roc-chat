// **SAVE, THE SCRIPT'S RULES, IN NODE** (js/save.js), run by verify: with a
// stubbed page (its bubbles, its keys, its feed, its fetch), the page's
// saved numbers are marked "✓ saved" and the rest "save"; s with nothing
// selected keeps the key; the popup is pre-filled "read later", and only a
// committed note is POSTed (`n=`, `note=`); a bubble is marked only once
// the save is confirmed, never before, and the strip names its reference
// and the list; a refusal or a lost answer says "Save failed". One line a
// check, PASS or FAIL, then exit 1 when any failed.
//
//   node tools/save_test.js
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'js', 'save.js'), 'utf8');

// An element, as much of one as save.js touches.
function element(tag) {
  const el = {
    tag, style: {}, children: [], listeners: {}, dataset: {}, textContent: '', value: '',
    classes: new Set(),
    appendChild(c) { el.children.push(c); return c; },
    addEventListener(t, fn) { (el.listeners[t] = el.listeners[t] || []).push(fn); },
    fire(t, e) { (el.listeners[t] || []).forEach((fn) => fn(e || {})); },
    remove() { el.removed = true; },
    focus() {}, select() {},
    showModal() { el.open = true; },
    close() { el.open = false; el.fire('close'); },
  };
  el.classList = { add: (c) => el.classes.add(c), contains: (c) => el.classes.has(c), toggle: (c, on) => (on ? el.classes.add(c) : el.classes.delete(c)) };
  return el;
}
function bubble(id) {
  const b = element('div');
  b.dataset.id = String(id);
  b.classes.add('chat-msg');
  const button = element('button');
  b.querySelector = (sel) => (sel === '.msg-save' ? button : null);
  b.button = button;
  return b;
}

function page(savedAttr, drawn) {
  const did = { posted: [], revealed: [], dialogs: [] };
  const keys = {};
  const answers = [];
  const notify = element('div');
  const bubbles = element('div');
  bubbles.querySelectorAll = () => drawn;
  const document = {
    head: element('head'),
    body: element('body'),
    getElementById: (id) => (id === 'chat-bubbles' ? bubbles : id === 'chat-notify' ? notify : null),
    createTextNode: (text) => ({ textContent: text }),
    createElement: (tag) => {
      const el = element(tag);
      if (tag === 'dialog') did.dialogs.push(el);
      return el;
    },
  };
  document.body.dataset = { saved: savedAttr, save: '/t/save' };
  const state = { selected: null };
  const ctx = {
    window: {}, document,
    MutationObserver: function () { this.observe = () => {}; },
    URLSearchParams,
    Keys: { register: (e) => { keys[e.key] = e; } },
    Feed: { selected: () => state.selected, reveal: (b) => did.revealed.push(b), focus: () => {} },
    fetch: (url, opts) => { did.posted.push({ url, body: opts.body }); return new Promise((resolve, reject) => answers.push({ resolve, reject })); },
  };
  vm.runInNewContext(source, ctx);
  // The popup's note: commit it (Enter or Save), or dismiss it.
  const dialog = () => did.dialogs[did.dialogs.length - 1];
  const input = () => dialog().children[0].children[1];
  const commit = (note) => { if (note !== undefined) input().value = note; dialog().children[0].fire('submit'); dialog().close(); };
  const dismiss = () => dialog().close();
  const ok = (json) => answers.shift().resolve({ status: 201, json: () => Promise.resolve(json) });
  const refused = () => answers.shift().resolve({ status: 413, json: () => Promise.resolve({}) });
  const lost = () => answers.shift().reject(new Error('Failed to fetch'));
  const settle = () => new Promise((r) => setImmediate(r));
  return { keys, did, state, notify, dialog, input, commit, dismiss, ok, refused, lost, settle };
}

let failed = 0;
function check(ok, what) {
  console.log((ok ? 'PASS' : 'FAIL') + '  save.js: ' + what);
  if (!ok) failed++;
}

(async () => {
  {
    const one = bubble(1), three = bubble(3);
    const p = page('3', [one, three]);
    check(three.button.textContent === '✓ saved' && three.button.classes.has('saved') && one.button.textContent === 'save' && !one.button.classes.has('saved'), 'the page\'s saved numbers are marked, the rest not');
    check(p.keys.s && !p.keys.s.hidden && p.keys.s.run() === false && p.did.dialogs.length === 0, 's with nothing selected keeps the key');
  }
  {
    const one = bubble(1);
    const p = page('', [one]);
    p.state.selected = one;
    check(p.keys.s.run() !== false && p.did.revealed[0] === one && p.input().value === 'read later', 's opens the popup pre-filled "read later", the message selected');
    p.dismiss();
    check(p.did.posted.length === 0 && p.dialog().removed, 'dismissed: nothing saved, the popup gone');
  }
  {
    const one = bubble(1);
    const p = page('', [one]);
    p.state.selected = one;
    p.keys.s.run();
    p.commit('look again');
    const form = new URLSearchParams(p.did.posted[0].body);
    check(p.did.posted[0].url === '/t/save' && form.get('n') === '1' && form.get('note') === 'look again', 'committed: n= and note= POSTed');
    check(one.button.textContent === 'save', 'not marked before the save is confirmed');
    p.ok({ ref: 'MSG_Orchard.Banana_1', list: '/chat/saved' });
    await p.settle();
    const strip = p.notify.children[0];
    check(one.button.textContent === '✓ saved' && one.button.classes.has('saved'), 'confirmed: marked "✓ saved"');
    check(strip && strip.children[0].textContent === 'MSG_Orchard.Banana_1 saved to ' && strip.children[1].href === '/chat/saved' && strip.children[1].textContent === 'your reading list', 'the strip names the reference, the list linked');
  }
  {
    const one = bubble(1);
    const p = page('', [one]);
    p.state.selected = one;
    p.keys.s.run();
    p.commit();
    p.refused();
    await p.settle();
    check(p.notify.textContent === 'Save failed' && one.button.textContent === 'save', 'a refusal: "Save failed", not marked');
    p.keys.s.run();
    p.commit();
    p.lost();
    await p.settle();
    check(p.notify.textContent === 'Save failed' && one.button.textContent === 'save', 'a lost answer: "Save failed", not marked');
  }
  process.exit(failed === 0 ? 0 : 1);
})();
