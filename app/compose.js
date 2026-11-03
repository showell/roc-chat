// This script runs on a conversation page, which app/Page.roc builds and
// app/ComposeScript.roc serves. The page works without it: the form posts,
// and the messages read top to bottom. The script makes the messages fill
// the window above a fixed compose box, and makes Ctrl+Enter (⌘+Enter on a
// Mac) send, as chat-client does; plain Enter is a new line.
//
// New messages arrive on the conversation's stream as the page's own HTML,
// and the script appends them. The view follows them when it was at or near
// the newest message. When the connection drops, the browser
// reconnects by itself and says the last message it saw, so the server
// sends only what was missed. If the stream dies for good, the page
// reloads itself; if it dies again soon after, the page says so instead.
//
// The script styles what it arranges, so the server sends no CSS.
(function () {
  'use strict';
  var messages = document.querySelector('.messages');
  var compose = document.querySelector('.compose');
  var form = compose && compose.querySelector('form');
  var box = form && form.querySelector('textarea');
  var send = form && form.querySelector('button');
  var help = compose && compose.querySelector('.help');
  if (!messages || !box || !send || !help) {
    throw new Error('compose.js: the page has no .messages, or no .compose with a form, its textarea, its button and .help');
  }
  var stream = messages.getAttribute('data-stream');
  var after = messages.getAttribute('data-after');
  if (!stream || !/^[0-9]+$/.test(after || '')) {
    throw new Error('compose.js: .messages has no data-stream, or a data-after that is no count');
  }

  var body = document.body;
  body.style.margin = '0 auto';
  body.style.height = '100vh';
  body.style.display = 'flex';
  body.style.flexDirection = 'column';
  messages.style.flex = '1 1 auto';
  messages.style.minHeight = '0';
  messages.style.overflowY = 'auto';
  compose.style.flex = 'none';
  compose.style.borderTop = '1px solid #ccc';
  compose.style.padding = '.5rem 0';
  form.style.display = 'flex';
  form.style.gap = '.5rem';
  form.style.alignItems = 'flex-end';
  box.rows = 3;
  box.style.flex = '1 1 auto';
  box.style.font = 'inherit';
  box.style.resize = 'vertical';
  help.style.margin = '.25rem 0 0';
  help.style.color = '#777';
  help.style.fontSize = '.85em';

  function scrollToNewest() { messages.scrollTop = messages.scrollHeight; }
  scrollToNewest();
  // Images lay out late; the newest message stays in view once they have.
  window.addEventListener('load', scrollToNewest);
  box.focus();

  // One send per page: a second Ctrl+Enter while the first is on its way would
  // post the message twice. A page shown again from the back button's cache
  // may send again.
  var sending = false;
  form.addEventListener('submit', function () { sending = true; });
  window.addEventListener('pageshow', function () { sending = false; });
  box.addEventListener('keydown', function (e) {
    if (e.key !== 'Enter' || !(e.ctrlKey || e.metaKey) || e.isComposing) return;
    e.preventDefault();
    if (sending || box.value.trim() === '') return;
    form.requestSubmit(send);
  });

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
    messages.insertAdjacentHTML('beforeend', e.data);
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
    notice.style.margin = '0';
    notice.style.padding = '.5rem';
    notice.style.background = '#fdd';
    notice.style.color = '#600';
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
