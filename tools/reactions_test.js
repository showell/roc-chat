// **REACTIONS, THE SCRIPT'S RULES, IN NODE** (js/reactions.js), run by
// verify: with a stubbed page (its bubbles, keys, feed, fetch), a chip's
// click asks for the state it is not in (on when the viewer is not on it,
// off when they are, by the server's data-by); + toggles 👍 on the selected
// message; : and + with nothing selected keep the key; : opens the picker
// over the selection, the old list filtered as typed, Enter picking the
// highlighted row (Up/Down moving it), Esc closing it with nothing sent and
// the keyboard back to the transcript; nothing is painted before the
// server's event; a refusal or a lost answer says "Reaction failed". One
// line a check, PASS or FAIL, then exit 1 when any failed.
//
//   node tools/reactions_test.js
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const emoji = fs.readFileSync(path.join(__dirname, '..', 'js', 'emoji.js'), 'utf8');
const source = fs.readFileSync(path.join(__dirname, '..', 'js', 'reactions.js'), 'utf8');

function element(tag) {
  const el = {
    tag, style: {}, children: [], listeners: {}, dataset: {}, textContent: '', value: '', removed: false,
    classes: new Set(),
    appendChild(c) { el.children.push(c); return c; },
    addEventListener(t, fn) { (el.listeners[t] = el.listeners[t] || []).push(fn); },
    fire(t, e) { const ev = Object.assign({ preventDefault() {} }, e || {}); (el.listeners[t] || []).forEach((fn) => fn(ev)); },
    remove() { el.removed = true; },
    focus() {},
    getBoundingClientRect() { return { left: 0, top: 0 }; },
  };
  el.classList = { add: (c) => el.classes.add(c), contains: (c) => el.classes.has(c), toggle: (c, on) => (on ? el.classes.add(c) : el.classes.delete(c)) };
  Object.defineProperty(el, 'textContent', { get() { return el._text || ''; }, set(v) { el._text = v; if (v === '') el.children = []; } });
  return el;
}
function bubble(id, chips) {
  const b = element('div');
  b.dataset.id = String(id);
  b.querySelectorAll = () => chips.map(([emoji, by]) => ({ dataset: { emoji, by } }));
  return b;
}

function page() {
  const did = { posted: [], focused: 0, revealed: 0 };
  const keys = {};
  const answers = [];
  const notify = element('div');
  const bubbles = element('div');
  const body = element('body');
  body.dataset = { me: 'human:1', react: '/t/react' };
  const document = {
    head: element('head'), body,
    getElementById: (id) => (id === 'chat-bubbles' ? bubbles : id === 'chat-notify' ? notify : null),
    createElement: element,
  };
  const state = { selected: null };
  const ctx = {
    window: { innerHeight: 800 }, document, URLSearchParams,
    Keys: { register: (e) => { keys[e.key] = e; } },
    Feed: { selected: () => state.selected, reveal: () => { did.revealed++; }, focus: () => { did.focused++; } },
    fetch: (url, opts) => { did.posted.push({ url, form: new URLSearchParams(opts.body) }); return new Promise((resolve, reject) => answers.push({ resolve, reject })); },
  };
  ctx.window.innerHeight = 800;
  ctx.innerHeight = 800;
  vm.createContext(ctx);
  vm.runInContext(emoji, ctx);
  ctx.Emoji = ctx.window.Emoji;
  vm.runInContext(source, ctx);
  const menu = () => body.children[body.children.length - 1];
  const input = () => menu().children[0];
  const rows = () => menu().children[1].children;
  const answer = (status) => answers.shift().resolve({ status });
  const lost = () => answers.shift().reject(new Error('Failed to fetch'));
  const settle = () => new Promise((r) => setImmediate(r));
  const click = (target) => bubbles.fire('click', { target });
  return { keys, did, state, notify, menu, input, rows, answer, lost, settle, click };
}

let failed = 0;
function check(ok, what) {
  console.log((ok ? 'PASS' : 'FAIL') + '  reactions.js: ' + what);
  if (!ok) failed++;
}

(async () => {
  {
    const p = page();
    check(p.keys[':'] && p.keys['+'] && !p.keys[':'].hidden && !p.keys['+'].hidden, ': and + in the panel');
    check(p.keys[':'].run() === false && p.keys['+'].run() === false && p.did.posted.length === 0, 'with nothing selected, : and + keep the key');
  }
  {
    const p = page();
    const b = bubble(4, [['👍', 'human:2 human:1'], ['🎉', 'human:2']]);
    const chip = (emoji) => ({ dataset: { emoji }, closest: (sel) => (sel === '.chat-react-chip' ? chip.self : sel === '.chat-msg' ? b : null) });
    const mine = chip('👍'); chip.self = mine;
    p.click(mine);
    check(p.did.posted[0].url === '/t/react' && p.did.posted[0].form.get('msg') === '4' && p.did.posted[0].form.get('emoji') === '👍' && p.did.posted[0].form.get('on') === '0', 'my chip clicked: off');
    const theirs = chip('🎉'); chip.self = theirs;
    p.click(theirs);
    check(p.did.posted[1].form.get('emoji') === '🎉' && p.did.posted[1].form.get('on') === '1', "another's chip clicked: on");
  }
  {
    const p = page();
    p.state.selected = bubble(7, []);
    p.keys['+'].run();
    check(p.did.posted[0].form.get('msg') === '7' && p.did.posted[0].form.get('emoji') === '👍' && p.did.posted[0].form.get('on') === '1', '+ toggles 👍 on the selected message');
    p.answer(400);
    await p.settle();
    check(p.notify.textContent === 'Reaction failed', 'a refusal: "Reaction failed"');
    p.notify.textContent = '';
    p.keys['+'].run();
    p.lost();
    await p.settle();
    check(p.notify.textContent === 'Reaction failed', 'a lost answer: "Reaction failed"');
  }
  {
    const p = page();
    p.state.selected = bubble(9, []);
    p.keys[':'].run();
    check(p.rows().length === 26 && p.did.revealed === 1, ': opens the picker over the selection, the old 26');
    p.input().value = 'th';
    p.input().fire('input');
    check(p.rows().length === 3 && p.rows()[0].children[1].textContent === ':thinking:', 'typing filters by the name\'s start');
    p.input().fire('keydown', { key: 'ArrowDown' });
    p.input().fire('keydown', { key: 'Enter' });
    check(p.did.posted.length === 1 && p.did.posted[0].form.get('emoji') === '👍' && p.menu().removed && p.did.focused === 1, 'Down then Enter picks the second (👍), closes, the keyboard back');
  }
  {
    const p = page();
    p.state.selected = bubble(9, []);
    p.keys[':'].run();
    p.input().fire('keydown', { key: 'Escape' });
    check(p.menu().removed && p.did.posted.length === 0 && p.did.focused === 1, 'Esc closes, nothing sent, the keyboard back');
  }
  process.exit(failed === 0 ? 0 : 1);
})();
