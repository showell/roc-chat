// This script runs on a conversation page, which app/ConversationPage.roc
// builds and app/Script.roc serves. It holds the page's emojis, and the
// compose box's autocomplete of them, chat-client's (js/chat_emoji.js).
//
// The list below is the one home of the emojis: the autocomplete offers
// them, and actions.js's reaction picker and its `+` key take theirs from
// it (Emoji.glyphs, Emoji.glyphOf). Each is a name of lowercase letters and
// digits and its glyph, one code point, with the variation selector where
// the character is text by default. The server never sees a name.
//
// Typing `:` at the start of the box or after a space opens a menu of the
// emojis whose names start with what follows it, the first eight in the
// list's order, narrowing as you type; so `12:30`, `http://` and `a:b` never
// open it. The arrows move through the menu, Enter or Tab takes the
// highlighted emoji, and so does a click; Escape, or any character no name
// goes on with, closes it. Typing the closing colon of an exact name
// (`:tada:`) takes that emoji with no menu. The emoji's glyph replaces the
// `:name` in the box, with a space after it when it came from the menu, so
// the message sent already holds the glyph. Ctrl+Enter (⌘+Enter) still
// sends, and closes the menu; plain Enter is the box's new line only while
// the menu is closed.
//
// It runs after compose.js, so the box's own keys are handled first, as in
// chat-client, and before actions.js. The menu is a fixed overlay over the
// box's bottom left, styled here with palette.js's colours.
window.Emoji = (function () {
  'use strict';
  var compose = document.querySelector('.compose');
  var textarea = compose && compose.querySelector('textarea');
  if (!textarea) throw new Error('emoji.js: the page has no .compose with a textarea');

  // The menu's order is this order.
  var EMOJI = [
    { name: 'smile', glyph: '😄' },
    { name: 'joy', glyph: '😂' },
    { name: 'sob', glyph: '😭' },
    { name: 'wink', glyph: '😉' },
    { name: 'thinking', glyph: '🤔' },
    { name: 'thumbsup', glyph: '👍' },
    { name: 'thumbsdown', glyph: '👎' },
    { name: 'heart', glyph: '❤️' }, // The red heart is text without its variation selector.
    { name: 'tada', glyph: '🎉' },
    { name: 'rocket', glyph: '🚀' },
    { name: 'fire', glyph: '🔥' },
    { name: 'eyes', glyph: '👀' },
    { name: '100', glyph: '💯' },
    { name: 'check', glyph: '✅' },
    { name: 'wave', glyph: '👋' },
    // Fitness.
    { name: 'muscle', glyph: '💪' },
    { name: 'run', glyph: '🏃' },
    { name: 'bike', glyph: '🚴' },
    { name: 'swim', glyph: '🏊' },
    // Money.
    { name: 'moneybag', glyph: '💰' },
    { name: 'dollar', glyph: '💵' },
    { name: 'chartup', glyph: '📈' },
    { name: 'chartdown', glyph: '📉' },
    // Robots.
    { name: 'robot', glyph: '🤖' },
    { name: 'invader', glyph: '👾' },
    { name: 'brain', glyph: '🧠' },
  ];
  // The menu is a fast path: the top matches only.
  var COMPOSE_ROWS = 8;

  var s = document.createElement('style');
  s.textContent = [
    '.chat-emoji-menu { position:fixed; z-index:20; box-sizing:border-box;' +
      ' background:var(--cc-card-bg); color:var(--cc-fg);' +
      ' border:1px solid var(--cc-dialog-border); border-radius:6px;' +
      ' padding:4px 0; font-size:14px; box-shadow:0 4px 14px var(--cc-backdrop); }',
    '.chat-emoji-list { max-height:232px; overflow-y:auto; }',
    '.chat-emoji-row { display:flex; align-items:center; gap:10px; padding:4px 12px; cursor:pointer; }',
    '.chat-emoji-row.chat-emoji-sel { background:var(--cc-search-sel-bg); }',
    '.chat-emoji-glyph { width:1.4em; text-align:center; }',
    '.chat-emoji-name { color:var(--cc-muted-fg); font-family:ui-monospace,Menlo,Consolas,monospace; font-size:13px; }',
  ].join('\n');
  document.head.appendChild(s);

  // The shortcode under the caret: {start, query}, `start` the index of its
  // opening colon, or null when the caret is not right after a `:name` run.
  // A bare colon is one, its name empty.
  function shortcodeAtCaret() {
    var at = textarea.selectionStart;
    if (at !== textarea.selectionEnd) return null;
    var m = /(^|\s):([a-z0-9]*)$/.exec(textarea.value.slice(0, at));
    if (!m) return null;
    return { start: m.index + m[1].length, query: m[2] };
  }

  function matches(query, limit) {
    var out = [];
    for (var i = 0; i < EMOJI.length && out.length < limit; i++) {
      if (EMOJI[i].name.indexOf(query) === 0) out.push(EMOJI[i]);
    }
    return out;
  }

  function exactMatch(query) {
    for (var i = 0; i < EMOJI.length; i++) if (EMOJI[i].name === query) return EMOJI[i];
    return null;
  }

  function glyphOf(name) {
    var entry = exactMatch(name);
    if (!entry) throw new Error('Emoji.glyphOf: no emoji is named "' + name + '"');
    return entry.glyph;
  }

  // The floating menu: a list of rows, one highlighted, kept in view by a
  // snap scroll, never a smooth one.
  function createMenu(onAccept) {
    var el = null, list = null, rows = [], sel = 0;
    function close() { if (el) el.remove(); el = null; list = null; rows = []; sel = 0; }
    function paint() {
      for (var i = 0; i < list.children.length; i++) {
        list.children[i].classList.toggle('chat-emoji-sel', i === sel);
      }
      if (list.children[sel]) list.children[sel].scrollIntoView({ block: 'nearest' });
    }
    function show(entries) {
      if (!el) {
        el = document.createElement('div');
        el.className = 'chat-emoji-menu';
        list = document.createElement('div');
        list.className = 'chat-emoji-list';
        el.appendChild(list);
        document.body.appendChild(el);
      }
      rows = entries;
      if (sel >= rows.length) sel = 0;
      list.textContent = '';
      rows.forEach(function (entry, i) {
        var row = document.createElement('div');
        row.className = 'chat-emoji-row';
        var g = document.createElement('span');
        g.className = 'chat-emoji-glyph';
        g.textContent = entry.glyph;
        var n = document.createElement('span');
        n.className = 'chat-emoji-name';
        n.textContent = ':' + entry.name + ':';
        row.appendChild(g);
        row.appendChild(n);
        // A mousedown, not a click: a click would first blur the box, which closes the menu.
        row.addEventListener('mousedown', function (e) { e.preventDefault(); onAccept(entry); });
        row.addEventListener('mousemove', function () { if (sel !== i) { sel = i; paint(); } });
        list.appendChild(row);
      });
      paint();
    }
    function move(delta) { if (rows.length) { sel = (sel + delta + rows.length) % rows.length; paint(); } }
    function accept() { if (rows.length) onAccept(rows[sel]); }
    function resetSel() { sel = 0; }
    function place(style) { Object.assign(el.style, style); }
    function isOpen() { return !!el; }
    return { show: show, close: close, move: move, accept: accept, resetSel: resetSel, place: place, isOpen: isOpen };
  }

  var hit = null; // The shortcode the menu is open for.
  var menu = createMenu(function (entry) { insert(entry, ' '); });

  // Replaces the `:query` run with the glyph and `tail`, the caret after them.
  function insert(entry, tail) {
    textarea.setRangeText(entry.glyph + tail, hit.start, textarea.selectionStart, 'end');
    menu.close();
    hit = null;
    textarea.focus();
  }

  function refresh() {
    var h = shortcodeAtCaret();
    var found = h ? matches(h.query, COMPOSE_ROWS) : [];
    if (found.length === 0) { menu.close(); hit = null; return; }
    if (!hit || hit.start !== h.start) menu.resetSel();
    hit = h;
    menu.show(found);
    var r = textarea.getBoundingClientRect();
    menu.place({ left: (r.left + 6) + 'px', width: Math.max(120, r.width - 12) + 'px',
      top: '', bottom: (window.innerHeight - r.bottom + 6) + 'px' });
  }

  textarea.addEventListener('input', refresh);
  textarea.addEventListener('click', refresh);
  textarea.addEventListener('blur', function () { menu.close(); hit = null; });
  textarea.addEventListener('keydown', function (e) {
    // Ctrl+Enter sends; the menu never sits over a sent box.
    if (e.ctrlKey || e.metaKey || e.altKey) { menu.close(); hit = null; return; }
    if (e.key === ':') {
      var h = shortcodeAtCaret();
      var exact = h && exactMatch(h.query);
      if (exact) { e.preventDefault(); hit = h; insert(exact, ''); }
      return;
    }
    if (!menu.isOpen()) return;
    if (e.key === 'ArrowDown') { e.preventDefault(); menu.move(1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); menu.move(-1); }
    else if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); menu.accept(); }
    else if (e.key === 'Escape') { e.preventDefault(); menu.close(); hit = null; }
  });

  return {
    glyphs: EMOJI.map(function (entry) { return entry.glyph; }),
    glyphOf: glyphOf,
  };
})();
