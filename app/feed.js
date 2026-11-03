// This script runs on a conversation page, which app/Page.roc builds and
// app/Script.roc serves. It looks after the messages pane. The page
// works without it: the messages read top to bottom, each with its time in
// UTC.
//
// Each message is a bubble, as roc-chat's feed.js draws them, which is as
// chat-client drew them (js/message.js). The viewer's own messages sit on the
// right in one colour, everyone else's on the left in another. One message's
// HTML is the same for every viewer, so the script decides which is which:
// the messages pane names the viewer's id (data-viewer) and each message its
// author's (data-author). A message by someone who is not a user of the chat
// names no author, so it is never the viewer's. Each time is written in the
// viewer's own time zone, "Nov 2 · 7:11 PM", which the server doesn't know.
//
// The pane is a card at most 600 pixels wide, as chat-client's middle pane
// was, and is the only part of the page that scrolls. It starts at the newest
// message.
//
// New messages arrive on the conversation's stream as the page's own HTML,
// and each is dressed as the page's messages are, then appended. The view
// follows them when it was at or near the newest message. When the
// connection drops, the browser reconnects by itself and says the last
// message it saw, so the server sends only what was missed. If the stream
// dies for good, the page reloads itself; if it dies again soon after, the
// page says so instead. Each message the stream brings is handed to
// compose.js (Compose.arrived), which says when one this page sent arrives.
//
// One message is selected, ringed, as chat-client's message view did
// (js/message_view.js). The page starts with the newest selected. The arrow
// keys move the selection to the next or previous message, Home and End to
// the first or last, and Page Up and Page Down scroll a page, or select the
// first or last message when there is no further to scroll. Scrolling
// selects the first message wholly in view, and a click selects the message
// clicked. Once the selection has rested for 700 ms, the address bar's
// #msg-<n> names it, so a reload or a copied address comes back to it; an
// address that arrived with its own #msg-<n> keeps it until the reader
// moves. The keys are registered in compose.js's table (Keys), so the
// keyboard help lists them.
(function () {
  'use strict';
  var messages = document.querySelector('.messages');
  var compose = document.querySelector('.compose');
  if (!messages || !compose) throw new Error('feed.js: the page has no .messages, or no .compose');
  if (!window.Keys || !window.Compose) throw new Error('feed.js: compose.js runs first, and gives Keys and Compose');
  var stream = messages.getAttribute('data-stream');
  var after = messages.getAttribute('data-after');
  var viewer = messages.getAttribute('data-viewer');
  if (!stream || !/^[0-9]+$/.test(after || '') || !viewer) {
    throw new Error('feed.js: .messages has no data-stream, no data-viewer, or a data-after that is no count');
  }

  var s = document.createElement('style');
  s.textContent = [
    '.messages { flex: 1 1 auto; min-width: 0; min-height: 0; max-width: 600px; overflow-y: auto; box-sizing: border-box;' +
      ' border: 1px solid var(--cc-border); border-radius: 8px; padding: 12px; background: var(--cc-card-bg); }',
    '.messages:focus { outline: none; }',
    '.messages .empty { color: var(--cc-muted-fg); margin: 0; }',
    '.message.selected { box-shadow: 0 0 0 2px var(--cc-select-ring); }',
    '.message { margin: 0 0 12px; padding: 8px 10px; border-radius: 8px; max-width: 88%; }',
    '.message.mine { background: var(--cc-mine-bg); margin-left: auto; }',
    '.message.theirs { background: var(--cc-theirs-bg); margin-right: auto; }',
    '.message > header { font-size: 11px; color: var(--cc-muted-fg); margin-bottom: 3px; }',
    '.message > header .ref { color: inherit; text-decoration: none; }',
    '.message > header .ref:hover { text-decoration: underline; }',
    '.message .body { overflow-wrap: anywhere; }',
    '.message .body p:first-child { margin-top: 0; }',
    '.message .body p:last-child { margin-bottom: 0; }',
    '.message .body a.msg-ref { font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 0.9em;' +
      ' background: var(--cc-accent-soft-bg); color: var(--cc-accent); padding: 0 4px; border-radius: 3px; text-decoration: none; }',
    '.message .body a.msg-ref:hover { background: var(--cc-accent-soft-hov); }',
    '.message .body pre { background: var(--cc-code-bg); padding: 8px; border-radius: 4px; overflow-x: auto; }',
    '.message .body img { max-width: 100%; max-height: 320px; width: auto; height: auto; display: block; margin: 6px 0; border-radius: 6px; }',
    '.message .body video { max-width: 100%; max-height: 480px; display: block; margin: 6px 0; border-radius: 6px; }',
    '.message .body table { border-collapse: collapse; }',
    '.message .body td, .message .body th { border: 1px solid var(--cc-border); padding: 0 .4rem; }',
  ].join('\n');
  document.head.appendChild(s);

  // The time chat-client wrote: the viewer's zone, as "Nov 2 · 7:11 PM".
  function formatLocalTime(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '';
    var day = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(d);
    var time = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }).format(d);
    return day + ' · ' + time;
  }

  // What the script adds to a message the server drew: whose it is, and its
  // time in the viewer's zone. A time that doesn't read stays as the server
  // wrote it.
  function dress(message) {
    var mine = message.getAttribute('data-author') === viewer;
    message.classList.add(mine ? 'mine' : 'theirs');
    var t = message.querySelector('header time');
    var local = t && formatLocalTime(t.getAttribute('datetime'));
    if (local) {
      t.title = t.textContent;
      t.textContent = local;
    }
  }

  var drawn = messages.querySelectorAll('.message');
  for (var i = 0; i < drawn.length; i++) dress(drawn[i]);

  // A scroll the script makes is not the reader's, so it selects nothing.
  // The script's own scrolls are a window that stays open until 150 ms pass
  // with no scroll event, as chat-client's were: a flag cleared by the next
  // event would stay set after a scroll that moved nothing, and the
  // reader's next scroll would be taken for the script's.
  var SCROLL_QUIET_MS = 150;
  var ours = false;
  var oursTimer = null;
  function quiet() {
    if (oursTimer) clearTimeout(oursTimer);
    oursTimer = setTimeout(function () { ours = false; oursTimer = null; }, SCROLL_QUIET_MS);
  }
  function scrollAsScript(move) {
    ours = true;
    quiet();
    move();
  }

  function scrollToNewest() {
    scrollAsScript(function () { messages.scrollTop = messages.scrollHeight; });
  }

  // The selection. The ring moves at once, a message a key press; the
  // address bar follows once it rests, or at once for a click or a jump to
  // either end.
  var SETTLE_MS = 700;
  var REVEAL_PAD_TOP = 6;
  var REVEAL_PAD_BOTTOM = 48;
  var selected = null;
  var settleTimer = null;
  var arrivedWithHash = /^#msg-/.test(location.hash);
  function allMessages() { return Array.prototype.slice.call(messages.querySelectorAll('.message')); }
  function recordInAddress(article) {
    if (arrivedWithHash) return;
    window.history.replaceState(null, '', '#' + article.id);
  }
  function select(article, immediate) {
    if (settleTimer) { clearTimeout(settleTimer); settleTimer = null; }
    if (selected) selected.classList.remove('selected');
    selected = article;
    if (!article) return;
    article.classList.add('selected');
    if (immediate) recordInAddress(article);
    else settleTimer = setTimeout(function () { settleTimer = null; recordInAddress(article); }, SETTLE_MS);
  }
  // Scrolls just enough to bring `article` into view, with a little room
  // above it and more below.
  function reveal(article) {
    var pane = messages.getBoundingClientRect();
    var box = article.getBoundingClientRect();
    if (box.top < pane.top + REVEAL_PAD_TOP) {
      messages.scrollTop += box.top - pane.top - REVEAL_PAD_TOP;
    } else if (box.bottom > pane.bottom - REVEAL_PAD_BOTTOM) {
      var delta = box.bottom - (pane.bottom - REVEAL_PAD_BOTTOM);
      if (box.top - delta < pane.top + REVEAL_PAD_TOP) delta = box.top - pane.top - REVEAL_PAD_TOP;
      messages.scrollTop += delta;
    }
  }
  // The message scrolling selects: the first wholly in view; else the first
  // whose top is in view; else the one across the top edge.
  function selectionCandidate() {
    var pane = messages.getBoundingClientRect();
    var topInView = null;
    var acrossTop = null;
    var all = allMessages();
    for (var k = 0; k < all.length; k++) {
      var box = all[k].getBoundingClientRect();
      if (box.top >= pane.top - 1 && box.bottom <= pane.bottom + 1) return all[k];
      if (!topInView && box.top >= pane.top - 1 && box.top < pane.bottom) topInView = all[k];
      if (!acrossTop && box.top < pane.top && box.bottom > pane.top) acrossTop = all[k];
    }
    return topInView || acrossTop;
  }
  var framePending = false;
  messages.addEventListener('scroll', function () {
    if (ours) { quiet(); return; }
    if (framePending) return;
    framePending = true;
    requestAnimationFrame(function () {
      framePending = false;
      if (ours) return;
      var candidate = selectionCandidate();
      if (candidate && candidate !== selected) select(candidate, false);
    });
  });
  // A click selects in the capture phase, before a link in the message
  // acts, so a link to another message selects that one after.
  messages.addEventListener('click', function (e) {
    var article = e.target.closest && e.target.closest('.message');
    if (!article) return;
    arrivedWithHash = false;
    select(article, true);
  }, { capture: true });

  function moveSelection(step) {
    arrivedWithHash = false;
    var all = allMessages();
    if (!all.length) return;
    var at = all.indexOf(selected);
    if (at < 0) {
      at = all.indexOf(selectionCandidate());
      if (at < 0) at = 0;
    } else {
      at = Math.max(0, Math.min(all.length - 1, at + step));
    }
    var target = all[at];
    select(target, false);
    scrollAsScript(function () { reveal(target); });
  }
  function selectEnd(end) {
    arrivedWithHash = false;
    scrollAsScript(function () { messages.scrollTop = end === 'last' ? messages.scrollHeight : 0; });
    var all = allMessages();
    if (all.length) select(end === 'last' ? all[all.length - 1] : all[0], true);
  }
  // A page down (or up) while the pane can scroll that way; at its end, the
  // last (or first) message selected.
  function page(direction) {
    var canScroll = direction === 'up'
      ? messages.scrollTop > 0
      : messages.scrollTop + messages.clientHeight < messages.scrollHeight - 1;
    var step = Math.max(40, messages.clientHeight - 40);
    if (canScroll) messages.scrollTop += direction === 'up' ? -step : step;
    else selectEnd(direction === 'up' ? 'first' : 'last');
  }
  // Brings `article` to the middle of the pane and selects it: the sent
  // notice's link.
  function centre(article) {
    arrivedWithHash = false;
    scrollAsScript(function () {
      var pane = messages.getBoundingClientRect();
      var box = article.getBoundingClientRect();
      messages.scrollTop += (box.top + box.height / 2) - (pane.top + pane.height / 2);
    });
    select(article, true);
  }

  Keys.register({ key: 'ArrowDown', cap: '↓', label: 'next message', run: function () { moveSelection(1); } });
  Keys.register({ key: 'ArrowUp', cap: '↑', label: 'previous message', run: function () { moveSelection(-1); } });
  Keys.register({ key: 'Home', label: 'first message', run: function () { selectEnd('first'); } });
  Keys.register({ key: 'End', label: 'last message', run: function () { selectEnd('last'); } });
  Keys.register({ key: 'PageUp', cap: 'PgUp', label: 'a page up', run: function () { page('up'); } });
  Keys.register({ key: 'PageDown', cap: 'PgDn', label: 'a page down', run: function () { page('down'); } });
  window.Feed = { reveal: centre };

  scrollToNewest();
  var newestDrawn = allMessages().pop();
  if (newestDrawn) select(newestDrawn, true);
  // Images lay out late; the newest message stays in view once they have.
  window.addEventListener('load', scrollToNewest);

  // Whether the view is at or near the newest message, read before a new one
  // is appended below it. Near means the hidden part below is at most 15% of
  // the window's height (the whole window, compose box included): guessing
  // wrong not to follow is the worse mistake, especially on a phone.
  var NEAR_BOTTOM_FRACTION = 0.15;
  function nearNewest() {
    var hiddenBelow = messages.scrollHeight - messages.scrollTop - messages.clientHeight;
    return hiddenBelow <= window.innerHeight * NEAR_BOTTOM_FRACTION;
  }

  var events = new EventSource(stream + '?after=' + after);
  events.onmessage = function (e) {
    var follow = nearNewest();
    var empty = messages.querySelector('.empty');
    if (empty) empty.remove();
    var parsed = document.createElement('template');
    parsed.innerHTML = e.data;
    var arrived = Array.prototype.slice.call(parsed.content.querySelectorAll('.message'));
    for (var j = 0; j < arrived.length; j++) dress(arrived[j]);
    messages.appendChild(parsed.content);
    if (follow) {
      scrollToNewest();
      if (arrived.length) select(arrived[arrived.length - 1], false);
    }
    for (var k = 0; k < arrived.length; k++) Compose.arrived(arrived[k]);
  };
  // A stream that has closed for good doesn't reconnect, and the page would
  // go on looking fine. So the page reloads, unless it already reloaded for
  // this reason in the last minute; then it shows a notice and stops trying.
  var RELOAD_KEY = 'gopher-roc stream reloaded at';
  var RELOAD_WINDOW_MS = 60000;
  function reloadedRecently() {
    try {
      return Date.now() - Number(sessionStorage.getItem(RELOAD_KEY) || 0) < RELOAD_WINDOW_MS;
    } catch (err) {
      return true; // With no storage to count reloads, never risk a reload loop.
    }
  }
  function showLostNotice() {
    if (document.querySelector('.stream-lost')) return;
    var notice = document.createElement('p');
    notice.className = 'stream-lost';
    notice.textContent = 'The connection to the server was lost, and reloading did not bring it back. New messages will not appear until you reload the page.';
    notice.style.margin = '0 0 8px';
    notice.style.padding = '.5rem';
    notice.style.borderRadius = '6px';
    notice.style.background = 'var(--cc-lost-bg)';
    notice.style.color = 'var(--cc-lost-fg)';
    compose.insertBefore(notice, compose.firstChild);
  }
  function recoverStream() {
    if (reloadedRecently()) {
      showLostNotice();
      return;
    }
    try {
      sessionStorage.setItem(RELOAD_KEY, String(Date.now()));
    } catch (err) {
      showLostNotice();
      return;
    }
    location.reload();
  }
  events.onerror = function () {
    if (events.readyState === EventSource.CLOSED) recoverStream();
  };
  // A page restored from the back button's cache has a stream that was torn
  // down, so it reloads, as chat-client's does.
  window.addEventListener('pageshow', function (e) { if (e.persisted) location.reload(); });
})();
