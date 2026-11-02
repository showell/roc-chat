// **THE EMOJI AUTOCOMPLETE, THE SCRIPT'S RULES, IN NODE** (js/emoji.js), run
// by verify: with a stubbed compose box, `:` at a word's start opens the
// menu (the top 8 of the old 26), narrowing as typed, and nowhere else
// (mid-word, a time, a URL, a selection); Enter, Tab or a click puts the
// glyph and a space in place of the shortcode; the closing colon on an
// exact name puts the glyph alone, and on no name does nothing; Escape and
// Ctrl/⌘ close the menu, Escape held back from the box only while the menu
// is open; a name nobody has closes it, as leaving the box does. One line a
// check, PASS or FAIL, then exit 1 when any failed.
//
//   node tools/emoji_test.js
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'js', 'emoji.js'), 'utf8');

function element(tag) {
  const el = {
    tag, style: {}, children: [], listeners: {}, dataset: {}, removed: false,
    classes: new Set(),
    appendChild(c) { el.children.push(c); return c; },
    addEventListener(t, fn) { (el.listeners[t] = el.listeners[t] || []).push(fn); },
    remove() { el.removed = true; },
    focus() {},
    getBoundingClientRect() { return { left: 0, top: 0, bottom: 500, width: 300 }; },
  };
  el.classList = { add: (c) => el.classes.add(c), contains: (c) => el.classes.has(c), toggle: (c, on) => (on ? el.classes.add(c) : el.classes.delete(c)) };
  Object.defineProperty(el, 'textContent', { get() { return el._text || ''; }, set(v) { el._text = v; if (v === '') el.children = []; } });
  return el;
}

// A compose box: its text, its caret, and the events a person makes.
function box() {
  const body = element('body');
  const ctx = { window: { innerHeight: 800 }, document: { head: element('head'), body, createElement: element } };
  vm.createContext(ctx);
  vm.runInContext(source, ctx);
  const Emoji = ctx.window.Emoji;
  const ta = element('textarea');
  ta.value = '';
  ta.selectionStart = ta.selectionEnd = 0;
  ta.setRangeText = (text, start, end) => {
    ta.value = ta.value.slice(0, start) + text + ta.value.slice(end);
    ta.selectionStart = ta.selectionEnd = start + text.length;
  };
  const fire = (t, e) => {
    let prevented = false;
    const ev = Object.assign({ preventDefault() { prevented = true; } }, e || {});
    (ta.listeners[t] || []).forEach((fn) => fn(ev));
    return prevented;
  };
  Emoji.attach(ta);
  const menus = () => body.children.filter((m) => !m.removed);
  const rows = () => menus()[0].children[0].children;
  return {
    Emoji, ta, body, fire, menus, rows,
    // Typing `text` at the end: the input event after it.
    type(text) { ta.value += text; ta.selectionStart = ta.selectionEnd = ta.value.length; fire('input'); },
    key(k, more) { return fire('keydown', Object.assign({ key: k }, more || {})); },
    open: () => menus().length === 1,
    names: () => rows().map((r) => r.children[1].textContent),
  };
}

let failed = 0;
function check(ok, what) {
  console.log((ok ? 'PASS' : 'FAIL') + '  emoji.js: ' + what);
  if (!ok) failed++;
}

{
  const b = box();
  check(b.Emoji.glyphOf('thumbsup') === '👍' && b.Emoji.glyphOf('tada') === '🎉' && b.Emoji.glyphOf('nope') === null, 'glyphOf: a name\'s glyph, and none for no name');
  b.type(':');
  check(b.open() && b.rows().length === 8 && b.names()[0] === ':smile:', 'a bare : opens the top 8, the old order');
  b.type('th');
  check(b.names().join(' ') === ':thinking: :thumbsup: :thumbsdown:', 'typing narrows by the name\'s start');
  const held = b.key('Enter');
  check(held && b.ta.value === '🤔 ' && b.ta.selectionStart === b.ta.value.length && !b.open(), 'Enter puts the first glyph and a space in its place, the caret after, the menu closed');
}
{
  const b = box();
  b.type('hi :th');
  b.key('ArrowDown');
  b.key('Tab');
  check(b.ta.value === 'hi 👍 ' && !b.open(), 'Down then Tab: the second, after a word and a space');
}
{
  const b = box();
  b.type('hi :ro');
  b.rows()[0].listeners.mousedown[0]({ preventDefault() {} });
  check(b.ta.value === 'hi 🚀 ' && !b.open(), 'a click on a row puts its glyph');
}
for (const text of ['12:3', 'http:', 'a:b', 'x:']) {
  const b = box();
  b.type(text);
  check(!b.open(), 'no menu mid-word: ' + JSON.stringify(text));
}
{
  const b = box();
  b.type(':tada');
  const held = b.key(':');
  check(held && b.ta.value === '🎉' && !b.open(), 'the closing colon on an exact name: the glyph alone, the colon held back');
  const c = box();
  c.type(':tad');
  const kept = c.key(':');
  check(!kept && c.ta.value === ':tad', 'the closing colon on no exact name: nothing changed, the colon typed');
  const d = box();
  d.type('12:30');
  check(!d.key(':') && d.ta.value === '12:30', 'a colon mid-word completes nothing');
}
{
  const b = box();
  b.type(':zz');
  check(!b.open(), 'a name nobody has: no menu');
  b.ta.value = '';
  b.type(':s');
  check(b.open(), 'and one somebody has: the menu');
  const held = b.key('Escape');
  check(held && !b.open() && b.ta.value === ':s', 'Escape closes the menu alone, held back from the box');
  check(!b.key('Escape'), 'Escape with no menu goes to the box (compose.js)');
}
{
  const b = box();
  b.type(':s');
  const held = b.key('Enter', { ctrlKey: true });
  check(!held && !b.open() && b.ta.value === ':s', 'Ctrl-Enter closes the menu and is left to compose.js to send');
}
{
  const b = box();
  b.type(':s');
  b.fire('blur');
  check(!b.open(), 'leaving the box closes the menu');
  b.ta.selectionStart = 0;
  b.fire('click');
  check(!b.open(), 'a selection, or a caret after no shortcode: no menu');
}
process.exit(failed === 0 ? 0 : 1);
