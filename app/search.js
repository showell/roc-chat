// This script runs on a conversation page, which app/ConversationPage.roc
// builds, and on Recent (app/RecentFeed.roc), which a human watches for new
// activity; app/Script.roc serves it. It is chat-client's search palette
// (js/chat_search.js), across every topic the viewer may read, answered by
// the server (app/SearchRoute.roc): the server reads the words, and this
// script sends what was typed and shows what comes back.
//
// The / key and the 🔍 button it puts in the top bar open a dialog. On a
// conversation the key is in compose.js's table (Keys), which lists it in the
// keyboard help; Recent has no compose box, so no table, and the script
// listens for the key itself, by the table's rules: no text field focused,
// no modifier held. Typing asks /chat/search/words?prefix= for the
// words that begin so, each with how many messages hold it, once typing
// pauses for 150 ms. Enter, or a click, asks /chat/search/messages?word= for
// the messages holding the word chosen (or, with none chosen, what was
// typed), shown as excerpts with the word marked, in the server's order.
// Choosing one goes to it: in this topic, the message is brought into view;
// in another, its page opens at the message. Up and down choose, Escape
// steps back from the messages to the words, and from the words closes.
//
// An answer that is not to the newest question asked is dropped, so a slow
// answer to "la" never paints over the answer to "lay". The excerpts are
// text, put in as text nodes, never as markup.
//
// The script styles what it builds, with one style sheet of its own, so the
// server sends no CSS for it. Its colours are palette.js's.
(function () {
  'use strict';
  // A conversation's page is the one with a messages pane.
  var onConversation = !!document.querySelector('.messages');
  if (onConversation && (!window.Keys || !window.Feed)) {
    throw new Error('search.js: on a conversation, compose.js and feed.js run first, and give Keys and Feed');
  }
  var top = document.querySelector('.top-bar');
  var user = top && top.querySelector('.top-user');
  if (!user) throw new Error('search.js: the page has no .top-bar holding a .top-user');

  var WORDS_PATH = '/chat/search/words';
  var MESSAGES_PATH = '/chat/search/messages';
  // The server's shortest word, in UTF-8 bytes (SearchWords.shortest_word_bytes).
  var SHORTEST_WORD = 2;
  var DEBOUNCE_MS = 150;

  var styleSheet = document.createElement('style');
  styleSheet.textContent = [
    // Pinned to a fixed top offset, it grows downward as results fill in.
    '.search-dialog{position:fixed;top:56px;bottom:auto;left:0;right:0;margin:0 auto;width:600px;max-width:92vw;' +
      'max-height:calc(100vh - 80px);padding:0;border:1px solid var(--cc-quote-border);border-radius:10px;' +
      'background:var(--cc-bg);color:var(--cc-fg);display:flex;flex-direction:column}',
    '.search-dialog::backdrop{background:var(--cc-backdrop)}',
    '.search-input{margin:0;border:none;border-bottom:1px solid var(--cc-input-border);border-radius:10px 10px 0 0;' +
      'font-size:16px;padding:12px 16px;font-family:inherit;outline:none;background:var(--cc-bg);color:var(--cc-fg)}',
    '.search-status{font-size:12px;color:var(--cc-muted-fg);padding:6px 16px;border-bottom:1px solid var(--cc-soft-border);flex:none}',
    '.search-list{overflow-y:auto;padding:4px 0;flex:1 1 auto;min-height:0}',
    '.search-row{padding:7px 16px;cursor:pointer;border-left:3px solid transparent}',
    '.search-row.chosen{background:var(--cc-search-sel-bg);border-left-color:var(--cc-accent)}',
    '.search-row:hover{background:var(--cc-quote-bg)}',
    '.search-word{font-weight:bold;color:var(--cc-search-tok-fg);display:flex;align-items:baseline;gap:8px}',
    '.search-count{font-weight:normal;font-size:11px;color:var(--cc-soft-muted-fg)}',
    '.search-where{font-size:11px;color:var(--cc-muted-fg);margin-bottom:2px}',
    // A message's excerpt: the raw markdown around the word.
    '.search-excerpt{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;color:var(--cc-body-muted-fg);' +
      'white-space:pre-wrap;overflow-wrap:anywhere;margin-top:3px;max-height:4.6em;overflow:hidden}',
    '.search-dialog mark{background:var(--cc-search-mark-bg);color:inherit;border-radius:2px;padding:0}',
    '.search-open{background:none;border:none;cursor:pointer;font-size:16px;padding:0 6px;color:inherit}',
  ].join('\n');
  document.head.appendChild(styleSheet);

  function markedInto(node, before, mark, after) {
    if (before) node.appendChild(document.createTextNode(before));
    if (mark) { var m = document.createElement('mark'); m.textContent = mark; node.appendChild(m); }
    if (after) node.appendChild(document.createTextNode(after));
  }
  function utf8Length(text) { return new TextEncoder().encode(text).length; }
  function unreadableNote(n) { return n > 0 ? (' · ' + n + (n === 1 ? ' topic' : ' topics') + ' could not be read') : ''; }

  // The open dialog's state, or null: { dialog, input, list, status, phase
  // ('words' or 'messages'), items, chosen, word, timer }.
  var open = null;
  var asked = 0;
  function ask(url, done) {
    var mine = ++asked;
    fetch(url, { credentials: 'same-origin' }).then(function (r) {
      return r.json().then(function (j) { return { status: r.status, json: j }; },
        function () { return { status: r.status, json: null }; });
    }).then(function (a) {
      if (mine !== asked || !open) return;
      if (a.status === 401) { open.status.textContent = 'You are signed out; reload the page to sign in again.'; return; }
      if (a.status === 429) { open.status.textContent = 'Searching too fast; one moment and try again.'; return; }
      if (a.status !== 200 || !a.json) {
        open.status.textContent = 'Search failed (' + a.status + ')' + (a.json && a.json.error ? ': ' + a.json.error : '.');
        return;
      }
      done(a.json);
    }, function (err) {
      if (mine !== asked || !open) return;
      open.status.textContent = 'Search failed: the server could not be reached.';
      console.error('search: ' + url + ': ' + err);
    });
  }

  function paintChosen() {
    var rows = open.list.querySelectorAll('.search-row');
    for (var i = 0; i < rows.length; i++) rows[i].classList.toggle('chosen', i === open.chosen);
    if (open.chosen >= 0 && rows[open.chosen]) rows[open.chosen].scrollIntoView({ block: 'nearest' });
  }
  function clearList() { open.list.textContent = ''; open.items = []; open.chosen = -1; }
  function showPrompt() {
    clearList();
    open.status.textContent = 'Type at least ' + SHORTEST_WORD + ' characters to search every topic…';
  }

  // The list empties as soon as the text changes, so Enter before the new
  // words arrive searches what is typed, never a word left from before.
  function scheduleWords() {
    if (open.timer) clearTimeout(open.timer);
    var typed = open.input.value.trim();
    asked++;
    clearList();
    if (utf8Length(typed) < SHORTEST_WORD) { showPrompt(); return; }
    open.status.textContent = 'Searching…';
    open.timer = setTimeout(function () {
      if (open && open.phase === 'words') { open.timer = null; showWords(typed); }
    }, DEBOUNCE_MS);
  }
  function showWords(typed) {
    ask(WORDS_PATH + '?prefix=' + encodeURIComponent(typed), function (j) {
      if (open.phase !== 'words') return;
      clearList();
      var words = j.words || [];
      if (!words.length) {
        open.status.textContent = 'No word starts with “' + typed + '” — press Enter to search it anyway.' + unreadableNote(j.unreadable);
        return;
      }
      open.status.textContent = (words.length === j.most ? 'The top ' + j.most + ' words' : words.length + (words.length === 1 ? ' word' : ' words')) +
        ' · ↑↓ choose, Enter to search' + unreadableNote(j.unreadable);
      words.forEach(function (w, i) {
        var row = document.createElement('div'); row.className = 'search-row'; row.setAttribute('data-i', i);
        var head = document.createElement('div'); head.className = 'search-word';
        // Every word answered begins with the prefix as the server read it.
        var word = document.createElement('span'); markedInto(word, '', w.word.slice(0, j.prefix.length), w.word.slice(j.prefix.length));
        var count = document.createElement('span'); count.className = 'search-count'; count.textContent = w.count + (w.count === 1 ? ' msg' : ' msgs');
        head.appendChild(word); head.appendChild(count); row.appendChild(head);
        open.list.appendChild(row); open.items.push({ word: w.word });
      });
      open.chosen = 0; paintChosen();
    });
  }

  function isHere(page) { return page === location.pathname; }
  function whereLabel(m) {
    return isHere(m.page) ? (m.topic + ' (this topic)') : (m.place + ' · ' + m.topic + ' →');
  }
  function showMessages(word) {
    if (open.timer) { clearTimeout(open.timer); open.timer = null; }
    open.word = word; open.phase = 'messages'; clearList();
    open.status.textContent = 'Searching…';
    ask(MESSAGES_PATH + '?word=' + encodeURIComponent(word), function (j) {
      if (open.phase !== 'messages' || open.word !== word) return;
      var found = j.messages || [];
      if (!found.length) { open.status.textContent = 'No messages hold “' + word + '”. Esc to refine.' + unreadableNote(j.unreadable); return; }
      var shown = found.length < j.matched ? (' (the first ' + found.length + ' shown)') : '';
      open.status.textContent = j.matched + (j.matched === 1 ? ' message' : ' messages') + shown +
        ' — ↑↓ choose, Enter to go · Esc to refine' + unreadableNote(j.unreadable);
      found.forEach(function (m, k) {
        var row = document.createElement('div'); row.className = 'search-row'; row.setAttribute('data-i', k);
        var head = document.createElement('div'); head.className = 'search-where';
        head.textContent = whereLabel(m) + ' · ' + m.from + ' · ' + LocalTime.format(m.date);
        var excerpt = document.createElement('div'); excerpt.className = 'search-excerpt'; markedInto(excerpt, m.before, m.mark, m.after);
        row.appendChild(head); row.appendChild(excerpt);
        open.list.appendChild(row); open.items.push({ page: m.page, id: m.id });
      });
      open.chosen = 0; paintChosen();
    });
  }
  function searchChosen() {
    var item = open.items[open.chosen];
    var word = (item && item.word) ? item.word : open.input.value.trim();
    if (utf8Length(word) >= SHORTEST_WORD) showMessages(word);
  }
  function goToChosen() {
    var item = open.items[open.chosen];
    if (!item) return;
    close();
    var anchor = 'msg-' + item.id;
    var here = onConversation && isHere(item.page) && document.getElementById(anchor);
    if (here) {
      Feed.reveal(here);
      window.history.replaceState(null, '', '#' + anchor);
    } else {
      window.location.href = item.page + '#' + anchor;
    }
  }

  function onKey(e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); if (open.items.length) { open.chosen = Math.min(open.items.length - 1, open.chosen + 1); paintChosen(); } }
    else if (e.key === 'ArrowUp') { e.preventDefault(); if (open.items.length) { open.chosen = Math.max(0, open.chosen - 1); paintChosen(); } }
    else if (e.key === 'Enter') { e.preventDefault(); if (open.phase === 'words') searchChosen(); else goToChosen(); }
  }
  function onClick(e) {
    if (e.target === open.dialog) { close(); return; } // a click on the backdrop
    var row = e.target.closest && e.target.closest('.search-row');
    if (!row) return;
    open.chosen = parseInt(row.getAttribute('data-i'), 10); paintChosen();
    if (open.phase === 'words') searchChosen(); else goToChosen();
  }

  function show() {
    if (open) { open.input.focus(); return; }
    var dialog = document.createElement('dialog'); dialog.className = 'search-dialog';
    var input = document.createElement('input'); input.type = 'text'; input.className = 'search-input';
    input.placeholder = 'Search every topic…'; input.autocomplete = 'off';
    var status = document.createElement('div'); status.className = 'search-status';
    var list = document.createElement('div'); list.className = 'search-list';
    dialog.appendChild(input); dialog.appendChild(status); dialog.appendChild(list);
    document.body.appendChild(dialog);
    open = { dialog: dialog, input: input, list: list, status: status, phase: 'words', items: [], chosen: -1, word: '', timer: null };
    input.addEventListener('input', function () { open.phase = 'words'; scheduleWords(); });
    dialog.addEventListener('keydown', onKey);
    // Escape: from the messages, back to the words; from the words, closed.
    dialog.addEventListener('cancel', function (e) {
      e.preventDefault();
      if (!open) return;
      if (open.phase === 'messages') { open.phase = 'words'; open.input.focus(); scheduleWords(); }
      else close();
    });
    dialog.addEventListener('click', onClick);
    dialog.addEventListener('close', function () {
      if (open && open.timer) clearTimeout(open.timer);
      asked++;
      dialog.remove();
      open = null;
      var messages = document.querySelector('.messages');
      if (messages) messages.focus();
    });
    dialog.showModal(); input.focus(); showPrompt();
  }
  function close() { if (open) open.dialog.close(); }

  var button = document.createElement('button');
  button.type = 'button';
  button.className = 'search-open';
  button.textContent = '🔍';
  button.title = 'Search every topic (/)';
  button.setAttribute('aria-label', 'Search every topic');
  button.addEventListener('click', show);
  user.parentNode.insertBefore(button, user);

  if (onConversation) {
    Keys.register({ key: '/', label: 'search every topic', run: show });
  } else {
    document.addEventListener('keydown', function (e) {
      if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey) return;
      var focused = document.activeElement;
      if (focused && (focused.tagName === 'TEXTAREA' || focused.tagName === 'INPUT' || focused.isContentEditable)) return;
      e.preventDefault();
      show();
    });
  }
})();
