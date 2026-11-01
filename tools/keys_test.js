// **THE KEY TABLE'S RULES, IN NODE** (js/keys.js), run by verify: with a
// stubbed document, a key registered twice throws; the filter keeps a key
// from a textarea, an input or an editable element, and from Ctrl, Meta
// and Alt; a key's run that answers false leaves the browser's default;
// the panel's order is letters alphabetically, then `/ : +`, hidden keys
// out; and a register after the panel has read the table throws. One line
// a check, PASS or FAIL, then exit 1 when any failed.
//
//   node tools/keys_test.js
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'js', 'keys.js'), 'utf8');

// A fresh page: the document's one keydown listener, and its active element.
function page() {
  const doc = { listeners: [], activeElement: null };
  doc.addEventListener = (type, fn) => { if (type === 'keydown') doc.listeners.push(fn); };
  const window = {};
  vm.runInNewContext(source, { window, document: doc });
  const press = (key, mods = {}) => {
    const e = { key, ctrlKey: !!mods.ctrl, metaKey: !!mods.meta, altKey: !!mods.alt, prevented: false };
    e.preventDefault = () => { e.prevented = true; };
    doc.listeners.forEach((fn) => fn(e));
    return e;
  };
  return { Keys: window.Keys, doc, press };
}

let failed = 0;
function check(ok, what) {
  console.log((ok ? 'PASS' : 'FAIL') + '  keys.js: ' + what);
  if (!ok) failed++;
}
function throws(fn) {
  try { fn(); return false; } catch (e) { return true; }
}

{
  const { Keys } = page();
  Keys.register({ key: 'c', label: 'compose', run: () => {} });
  check(throws(() => Keys.register({ key: 'c', label: 'again', run: () => {} })), 'a key registered twice throws');
  check(!throws(() => Keys.register({ key: 'q', label: 'quote', run: () => {} })), 'another key registers');
}

{
  const { Keys, doc, press } = page();
  let runs = 0;
  Keys.register({ key: 'c', label: 'compose', run: () => { runs++; } });
  let e = press('c');
  check(runs === 1 && e.prevented, 'a plain key runs, its default prevented');
  for (const tag of ['TEXTAREA', 'INPUT']) {
    doc.activeElement = { tagName: tag };
    e = press('c');
    check(runs === 1 && !e.prevented, 'no key while typing in a ' + tag.toLowerCase());
  }
  doc.activeElement = { tagName: 'DIV', isContentEditable: true };
  e = press('c');
  check(runs === 1 && !e.prevented, 'no key in an editable element');
  doc.activeElement = { tagName: 'DIV' };
  for (const mod of ['ctrl', 'meta', 'alt']) {
    e = press('c', { [mod]: true });
    check(runs === 1 && !e.prevented, 'no key under ' + mod);
  }
  e = press('x');
  check(runs === 1 && !e.prevented, 'a key nobody registered passes through');
}

{
  const { Keys, press } = page();
  Keys.register({ key: 'q', label: 'quote', run: () => false });
  const e = press('q');
  check(!e.prevented, 'a run that did nothing (false) keeps the default');
}

{
  const { Keys } = page();
  for (const key of ['q', '+', 'c', ':', '/', 'a']) Keys.register({ key, label: key, run: () => {} });
  Keys.register({ key: 'ArrowUp', label: 'up', hidden: true, run: () => {} });
  const order = Keys.list().map((e) => e.key).join(' ');
  check(order === 'a c q / : +', 'the panel order is letters, then / : +, hidden keys out (got "' + order + '")');
  check(throws(() => Keys.register({ key: 'e', label: 'edit', run: () => {} })), 'a register after the panel read the table throws');
}

process.exit(failed === 0 ? 0 : 1);
