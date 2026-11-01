/* reactions.js: reactions, : and +, the old client's (chat-client's
   js/chat_reactions.js `toggle`; js/chat_emoji.js, its list and `pick`;
   js/chat.js `doPickReaction`, `thumbsUp`). The server keeps the events,
   folds them and draws each bubble's chips (app/Reactions.roc); a change
   comes to every page as a `reaction` event, which feed.js puts in place.
   This script:
     - a chip's click toggles that emoji on its message: on when the viewer
       is not on it, off when they are (the chip's data-by);
     - + toggles 👍 on the selected message;
     - : opens the picker over the selected message: the old list under a
       filter input, Up/Down to move, Enter or a click to pick, Esc or
       leaving the input to close, the transcript given the keyboard back;
     - a toggle POSTs the state wanted and waits for the event, never
       painting it itself (the old "never optimistic"); a refusal or no
       answer says "Reaction failed" in the strip.
   With nothing selected, : and + do nothing (the browser keeps the key).
   The menu is the old one's look, in one <style>, as the old widget's: it
   is the script's own markup, and its rows' :hover and selection are
   classes. */
(function () {
  'use strict';
  var root = document.body;
  var me = root.dataset.me;
  var bubbles = document.getElementById('chat-bubbles');
  var notify = document.getElementById('chat-notify');

  /* The old list, in the old order: the names are the filter's, the
     glyphs the reactions'. */
  var EMOJI = [
    { name: 'smile', glyph: '😄' }, { name: 'joy', glyph: '😂' }, { name: 'sob', glyph: '😭' },
    { name: 'wink', glyph: '😉' }, { name: 'thinking', glyph: '🤔' }, { name: 'thumbsup', glyph: '👍' },
    { name: 'thumbsdown', glyph: '👎' }, { name: 'heart', glyph: '❤️' }, { name: 'tada', glyph: '🎉' },
    { name: 'rocket', glyph: '🚀' }, { name: 'fire', glyph: '🔥' }, { name: 'eyes', glyph: '👀' },
    { name: '100', glyph: '💯' }, { name: 'check', glyph: '✅' }, { name: 'wave', glyph: '👋' },
    { name: 'muscle', glyph: '💪' }, { name: 'run', glyph: '🏃' }, { name: 'bike', glyph: '🚴' },
    { name: 'swim', glyph: '🏊' }, { name: 'moneybag', glyph: '💰' }, { name: 'dollar', glyph: '💵' },
    { name: 'chartup', glyph: '📈' }, { name: 'chartdown', glyph: '📉' }, { name: 'robot', glyph: '🤖' },
    { name: 'invader', glyph: '👾' }, { name: 'brain', glyph: '🧠' },
  ];
  var thumbsUp = '👍';

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

  /* Whether the viewer is on `emoji` on `bubble`, by the server's chip. */
  function isMine(bubble, emoji) {
    var chips = bubble.querySelectorAll('.chat-react-chip');
    for (var i = 0; i < chips.length; i++) {
      if (chips[i].dataset.emoji === emoji) return (chips[i].dataset.by || '').split(' ').indexOf(me) >= 0;
    }
    return false;
  }

  /* The old toggle: the state wanted POSTed; the event repaints. */
  function toggle(bubble, emoji) {
    var form = new URLSearchParams();
    form.set('msg', bubble.dataset.id);
    form.set('emoji', emoji);
    form.set('on', isMine(bubble, emoji) ? '0' : '1');
    fetch(root.dataset.react, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
    }).then(function (r) {
      if (r.status !== 204) notify.textContent = 'Reaction failed';
    }, function () { notify.textContent = 'Reaction failed'; });
  }

  function matches(query) {
    return EMOJI.filter(function (e) { return e.name.indexOf(query) === 0; });
  }

  /* The old pick: the list under a filter input, over `bubble`; `onPick`
     with the entry picked, and the keyboard back to the transcript once,
     picked or not. */
  function pick(bubble, onPick) {
    var closed = false, rows = [], sel = 0;
    var menu = document.createElement('div');
    menu.className = 'chat-emoji-menu';
    var input = document.createElement('input');
    input.className = 'chat-emoji-filter';
    input.placeholder = 'type to filter · Enter to react';
    var list = document.createElement('div');
    list.className = 'chat-emoji-list';
    menu.appendChild(input);
    menu.appendChild(list);
    function done() {
      if (closed) return;
      closed = true;
      menu.remove();
      Feed.focus();
    }
    function accept(entry) { done(); onPick(entry); }
    function paint() {
      for (var i = 0; i < list.children.length; i++) list.children[i].classList.toggle('chat-emoji-sel', i === sel);
      if (list.children[sel] && list.children[sel].scrollIntoView) list.children[sel].scrollIntoView({ block: 'nearest' });
    }
    function refresh() {
      rows = matches(input.value.trim().toLowerCase());
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
        /* mousedown, not click: a click would blur the input and close it first. */
        row.addEventListener('mousedown', function (e) { e.preventDefault(); accept(entry); });
        row.addEventListener('mousemove', function () { if (sel !== i) { sel = i; paint(); } });
        list.appendChild(row);
      });
      paint();
    }
    input.addEventListener('input', function () { sel = 0; refresh(); });
    input.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown') { e.preventDefault(); if (rows.length) { sel = (sel + 1) % rows.length; paint(); } }
      else if (e.key === 'ArrowUp') { e.preventDefault(); if (rows.length) { sel = (sel - 1 + rows.length) % rows.length; paint(); } }
      else if (e.key === 'Enter') { e.preventDefault(); if (rows.length) accept(rows[sel]); }
      else if (e.key === 'Escape') { e.preventDefault(); done(); }
    });
    input.addEventListener('blur', done);
    document.body.appendChild(menu);
    refresh();
    var r = bubble.getBoundingClientRect();
    Object.assign(menu.style, { left: r.left + 'px', width: '240px', top: Math.max(8, Math.min(r.top, window.innerHeight - 300)) + 'px' });
    input.focus();
    return menu;
  }

  bubbles.addEventListener('click', function (e) {
    var chip = e.target.closest && e.target.closest('.chat-react-chip');
    if (chip) toggle(chip.closest('.chat-msg'), chip.dataset.emoji);
  });
  Keys.register({
    key: ':', label: 'react to selected message (pick an emoji)',
    run: function () {
      var bubble = Feed.selected();
      if (!bubble) return false;
      Feed.reveal(bubble);
      pick(bubble, function (entry) { toggle(bubble, entry.glyph); });
    },
  });
  Keys.register({
    key: '+', label: 'thumbs-up the selected message',
    run: function () {
      var bubble = Feed.selected();
      if (!bubble) return false;
      toggle(bubble, thumbsUp);
    },
  });
})();
