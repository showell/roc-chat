// This script runs on a conversation page, which app/Page.roc builds and
// app/FeedScript.roc serves. It looks after the messages pane. The page
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
// page says so instead.
(function () {
  'use strict';
  var messages = document.querySelector('.messages');
  var compose = document.querySelector('.compose');
  if (!messages || !compose) throw new Error('feed.js: the page has no .messages, or no .compose');
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

  function scrollToNewest() { messages.scrollTop = messages.scrollHeight; }
  scrollToNewest();
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
    var arrived = parsed.content.querySelectorAll('.message');
    for (var j = 0; j < arrived.length; j++) dress(arrived[j]);
    messages.appendChild(parsed.content);
    if (follow) scrollToNewest();
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
