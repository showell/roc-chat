// **SAVE, THE SCRIPT'S RULES, IN NODE** (js/save.js), run by verify: with a
// stubbed page (its bubbles, its keys, its feed, its fetch), s with nothing
// selected keeps the key; s opens the popup pre-filled "read later" and
// leaves the selection be; Cancel and the backdrop dismiss it, nothing
// sent; a commit POSTs `n=` and `note=` and the popup waits; a confirmed
// save, never before, closes it, flips the bubble to "✓ saved" and puts the
// server's line in the strip; a refusal shows the server's words in the
// popup, which stays, and a lost answer "Save failed" there, the bubble
// left as it was. One line a check, PASS or FAIL, then exit 1 when any
// failed.
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
    tag, style: {}, children: [], listeners: {}, dataset: {}, textContent: '', value: '', disabled: false,
    classes: new Set(),
    appendChild(c) { el.children.push(c); return c; },
    addEventListener(t, fn) { (el.listeners[t] = el.listeners[t] || []).push(fn); },
    fire(t, e) { const ev = Object.assign({ preventDefault() { ev.prevented = true; } }, e || {}); (el.listeners[t] || []).forEach((fn) => fn(ev)); return ev; },
    remove() { el.removed = true; },
    focus() {}, select() {},
    showModal() { el.open = true; },
    close() { if (!el.open) return; el.open = false; el.fire('close'); },
  };
  el.classList = { add: (c) => el.classes.add(c), contains: (c) => el.classes.has(c), toggle: (c, on) => (on ? el.classes.add(c) : el.classes.delete(c)) };
  return el;
}
function bubble(id) {
  const b = element('div');
  b.dataset.id = String(id);
  const button = element('button');
  button.textContent = 'save';
  b.querySelector = (sel) => (sel === '.msg-save' ? button : null);
  b.button = button;
  return b;
}

function page() {
  const did = { posted: [], revealed: 0, dialogs: [] };
  const keys = {};
  const answers = [];
  const notify = element('div');
  const bubbles = element('div');
  const document = {
    head: element('head'),
    body: element('body'),
    getElementById: (id) => (id === 'chat-bubbles' ? bubbles : id === 'chat-notify' ? notify : null),
    createElement: (tag) => {
      const el = element(tag);
      if (tag === 'dialog') did.dialogs.push(el);
      if (tag === 'template') Object.defineProperty(el, 'innerHTML', { set(h) { el.content = { html: h }; } });
      return el;
    },
  };
  document.body.dataset = { save: '/t/save' };
  const state = { selected: null };
  const ctx = {
    window: {}, document, URLSearchParams,
    Keys: { register: (e) => { keys[e.key] = e; } },
    Feed: { selected: () => state.selected, reveal: () => { did.revealed++; }, focus: () => {} },
    fetch: (url, opts) => { did.posted.push({ url, body: opts.body }); return new Promise((resolve, reject) => answers.push({ resolve, reject })); },
  };
  vm.runInNewContext(source, ctx);
  const dialog = () => did.dialogs[did.dialogs.length - 1];
  const form = () => dialog().children[0];
  const input = () => form().children[1];
  const hint = () => form().children[2];
  const buttons = () => form().children[3].children;
  const commit = (note) => { if (note !== undefined) input().value = note; return form().fire('submit'); };
  const answer = (status, text) => answers.shift().resolve({ status, text: () => Promise.resolve(text) });
  const lost = () => answers.shift().reject(new Error('Failed to fetch'));
  const settle = () => new Promise((r) => setImmediate(r));
  return { keys, did, state, notify, dialog, input, hint, buttons, commit, answer, lost, settle };
}

let failed = 0;
function check(ok, what) {
  console.log((ok ? 'PASS' : 'FAIL') + '  save.js: ' + what);
  if (!ok) failed++;
}

(async () => {
  {
    const p = page();
    check(p.keys.s && !p.keys.s.hidden && p.keys.s.run() === false && p.did.dialogs.length === 0, 's with nothing selected keeps the key');
    const one = bubble(1);
    p.state.selected = one;
    check(p.keys.s.run() !== false && p.dialog().open && p.input().value === 'read later', 's opens the popup pre-filled "read later"');
    check(p.did.revealed === 0, 'the selection is left be, as the old doSave left it');
    p.buttons()[0].fire('click');
    check(!p.dialog().open && p.dialog().removed && p.did.posted.length === 0, 'Cancel dismisses: nothing sent, the popup gone');
    p.keys.s.run();
    p.dialog().fire('click', { target: p.dialog() });
    check(!p.dialog().open && p.did.posted.length === 0, 'the backdrop dismisses: nothing sent');
  }
  {
    const p = page();
    const one = bubble(1);
    p.state.selected = one;
    p.keys.s.run();
    const ev = p.commit('look again');
    const form = new URLSearchParams(p.did.posted[0].body);
    check(ev.prevented && p.did.posted[0].url === '/t/save' && form.get('n') === '1' && form.get('note') === 'look again', 'a commit POSTs n= and note=');
    check(p.dialog().open && one.button.textContent === 'save' && !one.button.classes.has('saved'), 'the popup waits; nothing marked before the save is confirmed');
    p.commit();
    check(p.did.posted.length === 1, 'a second Enter while one is out sends nothing');
    p.answer(201, '<span class=chat-saved-status>MSG_O.B_1 saved to <a href="/chat/saved">reading list</a></span>');
    await p.settle();
    check(!p.dialog().open && one.button.textContent === '✓ saved' && one.button.classes.has('saved'), 'confirmed: the popup closed, the bubble "✓ saved"');
    check(p.notify.children[0] && p.notify.children[0].html === '<span class=chat-saved-status>MSG_O.B_1 saved to <a href="/chat/saved">reading list</a></span>', "the strip is the server's line");
  }
  {
    const p = page();
    const one = bubble(1);
    p.state.selected = one;
    p.keys.s.run();
    p.commit();
    p.answer(413, 'your reading list is full (1048576 bytes): remove some saves first\n');
    await p.settle();
    check(p.dialog().open && p.hint().textContent === 'your reading list is full (1048576 bytes): remove some saves first', "a refusal: the server's words in the popup, which stays");
    check(one.button.textContent === 'save' && p.notify.children.length === 0, 'and nothing marked or said in the strip');
  }
  {
    const p = page();
    const one = bubble(1);
    p.state.selected = one;
    p.keys.s.run();
    p.commit();
    p.lost();
    await p.settle();
    check(p.dialog().open && p.hint().textContent === 'Save failed' && one.button.textContent === 'save' && p.notify.children.length === 0, 'a lost answer: "Save failed" in the popup, nothing marked');
  }
  process.exit(failed === 0 ? 0 : 1);
})();
