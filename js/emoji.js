/* emoji.js: the emoji list, the compose box's autocomplete, and the
   reaction picker, the old client's (chat-client's js/chat_emoji.js). The
   one home of the list: the picker (reactions.js) and the compose box
   (compose.js) both take it from here.
     - Emoji are the browser's: the list below is the one authority, and the
       server never sees a shortcode. Typing `:` at the start of a word in the
       compose box opens a menu (the list, narrowing as you type: the top 8);
       Enter, Tab or a click, or the closing colon on an exact name
       (`:tada:`), puts the glyph in place of the shortcode in the box, so
       the markdown sent already holds it.
     - The trigger is `:` at the start of the text or after whitespace, so
       `12:30`, `http://` and `a:b` never open it. The menu is for choosing:
       Escape, or a character no name has, closes it; Ctrl, ⌘ or Alt with a
       key closes it too (Ctrl/⌘-Enter sends, and the menu never sits over
       a sent box).
     - `pick`, the same menu with a filter input on top, every match in a
       scrolling list, is the reaction picker, over a bubble.
   Names are lowercase [a-z0-9]+; each glyph one codepoint (a variation
   selector after a base that is text by default), no ZWJ sequences, skin
   tones or flags. The menu's look is its own, one <style>, as the old
   widget's. */
window.Emoji = (function () {
  'use strict';

  /* The old list, in the old order: the menu's order, and the reactions'. */
  var EMOJI = [
    { name: 'smile', glyph: '😄' },
    { name: 'joy', glyph: '😂' },
    { name: 'sob', glyph: '😭' },
    { name: 'wink', glyph: '😉' },
    { name: 'thinking', glyph: '🤔' },
    { name: 'thumbsup', glyph: '👍' },
    { name: 'thumbsdown', glyph: '👎' },
    { name: 'heart', glyph: '❤️' }, /* a red heart is text without its VS16 */
    { name: 'tada', glyph: '🎉' },
    { name: 'rocket', glyph: '🚀' },
    { name: 'fire', glyph: '🔥' },
    { name: 'eyes', glyph: '👀' },
    { name: '100', glyph: '💯' },
    { name: 'check', glyph: '✅' },
    { name: 'wave', glyph: '👋' },
    /* fitness */
    { name: 'muscle', glyph: '💪' },
    { name: 'run', glyph: '🏃' },
    { name: 'bike', glyph: '🚴' },
    { name: 'swim', glyph: '🏊' },
    /* money */
    { name: 'moneybag', glyph: '💰' },
    { name: 'dollar', glyph: '💵' },
    { name: 'chartup', glyph: '📈' },
    { name: 'chartdown', glyph: '📉' },
    /* robots */
    { name: 'robot', glyph: '🤖' },
    { name: 'invader', glyph: '👾' },
    { name: 'brain', glyph: '🧠' },
  ];
  /* The compose menu is a fast path, the top matches only; the picker
     lists every match. */
  var composeRows = 8;

  var s = document.createElement('style');
  s.textContent = ''
    + '.chat-emoji-menu { position:fixed; z-index:20; box-sizing:border-box; background:var(--cc-card-bg); color:var(--cc-fg);'
    + ' border:1px solid var(--cc-dialog-border); border-radius:6px; padding:4px 0; font-size:14px; box-shadow:0 4px 14px var(--cc-backdrop); }'
    + '.chat-emoji-list { max-height:232px; overflow-y:auto; }'
    + '.chat-emoji-row { display:flex; align-items:center; gap:10px; padding:4px 12px; cursor:pointer; }'
    + '.chat-emoji-row.chat-emoji-sel { background:var(--cc-search-sel-bg); }'
    + '.chat-emoji-glyph { width:1.4em; text-align:center; }'
    + '.chat-emoji-name { color:var(--cc-muted-fg); font-family:ui-monospace,Menlo,Consolas,monospace; font-size:13px; }'
    + '.chat-emoji-filter { display:block; box-sizing:border-box; width:calc(100% - 16px); margin:2px 8px 6px; padding:4px 6px;'
    + ' font:inherit; font-size:13px; background:var(--cc-bg); color:var(--cc-fg); border:1px solid var(--cc-input-border); }';
  document.head.appendChild(s);

  /* The shortcode just before the caret: where its colon is and the name so
     far (a bare colon's is empty); none when text is selected or the caret
     follows no `:name` that starts a word. */
  function shortcodeAtCaret(textarea) {
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

  /* The glyph a name stands for, or null: + is `thumbsup`'s, by name. */
  function glyphOf(name) {
    for (var i = 0; i < EMOJI.length; i++) if (EMOJI[i].name === name) return EMOJI[i].glyph;
    return null;
  }

  /* One floating menu: rows, one highlighted, and an optional head above
     them. The autocomplete and the picker drive it; it knows neither. The
     highlight is kept in view by a snap, never a smooth scroll. */
  function createMenu(onAccept) {
    var el = null, list = null, rows = [], sel = 0;
    function close() { if (el) el.remove(); el = null; list = null; rows = []; sel = 0; }
    function paint() {
      for (var i = 0; i < list.children.length; i++) list.children[i].classList.toggle('chat-emoji-sel', i === sel);
      if (list.children[sel] && list.children[sel].scrollIntoView) list.children[sel].scrollIntoView({ block: 'nearest' });
    }
    function show(entries, head) {
      if (!el) {
        el = document.createElement('div');
        el.className = 'chat-emoji-menu';
        if (head) el.appendChild(head);
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
        /* mousedown, not click: a click would first blur the owner and close us. */
        row.addEventListener('mousedown', function (e) { e.preventDefault(); onAccept(entry); });
        row.addEventListener('mousemove', function () { if (sel !== i) { sel = i; paint(); } });
        list.appendChild(row);
      });
      paint();
    }
    return {
      show: show,
      close: close,
      move: function (delta) { if (rows.length) { sel = (sel + delta + rows.length) % rows.length; paint(); } },
      accept: function () { if (rows.length) onAccept(rows[sel]); },
      resetSel: function () { sel = 0; },
      place: function (style) { Object.assign(el.style, style); },
      isOpen: function () { return !!el; },
    };
  }

  /* The compose box's autocomplete, on `textarea`. */
  function attach(textarea) {
    var hit = null; /* the shortcode the menu is open for */
    var menu = createMenu(function (entry) { insert(entry, ' '); });

    /* The `:name` run replaced by the glyph (and `tail`), the caret after. */
    function insert(entry, tail) {
      textarea.setRangeText(entry.glyph + tail, hit.start, textarea.selectionStart, 'end');
      menu.close();
      hit = null;
      textarea.focus();
    }
    function shut() { menu.close(); hit = null; }

    /* Over the box's bottom edge, fixed, so the page keeps no room for it. */
    function refresh() {
      var h = shortcodeAtCaret(textarea);
      var list = h ? matches(h.query, composeRows) : [];
      if (list.length === 0) { shut(); return; }
      if (!hit || hit.start !== h.start) menu.resetSel();
      hit = h;
      menu.show(list, null);
      var r = textarea.getBoundingClientRect();
      menu.place({
        left: (r.left + 6) + 'px', width: Math.max(120, r.width - 12) + 'px',
        top: '', bottom: (window.innerHeight - r.bottom + 6) + 'px',
      });
    }

    textarea.addEventListener('input', refresh);
    textarea.addEventListener('click', refresh);
    textarea.addEventListener('blur', shut);
    textarea.addEventListener('keydown', function (e) {
      if (e.ctrlKey || e.metaKey || e.altKey) { shut(); return; }
      if (e.key === ':') {
        /* The closing colon on an exact name completes it in place. */
        var h = shortcodeAtCaret(textarea);
        var exact = h && glyphOf(h.query) !== null ? { glyph: glyphOf(h.query) } : null;
        if (exact) { e.preventDefault(); hit = h; insert(exact, ''); }
        return;
      }
      if (!menu.isOpen()) return;
      if (e.key === 'ArrowDown') { e.preventDefault(); menu.move(1); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); menu.move(-1); }
      else if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); menu.accept(); }
      /* The box holds the `:` while the menu is open, so compose.js's Esc
         (an empty box's) never closes the box with it. */
      else if (e.key === 'Escape') { e.preventDefault(); shut(); }
    });
  }

  /* The reaction picker: every match under a filter input, over `anchor`;
     Enter or a click picks (`onPick`), Escape or leaving the input closes,
     and `onClose` runs once either way, for the keyboard to go back. */
  function pick(opts) {
    var closed = false;
    var input = document.createElement('input');
    input.className = 'chat-emoji-filter';
    input.placeholder = 'type to filter · Enter to react';
    var menu = createMenu(function (entry) { done(); opts.onPick(entry); });
    function done() {
      if (closed) return;
      closed = true;
      menu.close();
      if (opts.onClose) opts.onClose();
    }
    function refresh() { menu.show(matches(input.value.trim().toLowerCase(), EMOJI.length), input); }
    input.addEventListener('input', function () { menu.resetSel(); refresh(); });
    input.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown') { e.preventDefault(); menu.move(1); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); menu.move(-1); }
      else if (e.key === 'Enter') { e.preventDefault(); menu.accept(); }
      else if (e.key === 'Escape') { e.preventDefault(); done(); }
    });
    input.addEventListener('blur', done);
    refresh();
    var r = opts.anchor.getBoundingClientRect();
    menu.place({ left: r.left + 'px', width: '240px', bottom: '', top: Math.max(8, Math.min(r.top, window.innerHeight - 300)) + 'px' });
    input.focus();
  }

  return { attach: attach, pick: pick, glyphOf: glyphOf };
})();
