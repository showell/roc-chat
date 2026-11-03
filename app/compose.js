// This script runs on a conversation page, which app/Page.roc builds and
// app/ComposeScript.roc serves. The page works without it: the form posts,
// and the messages read top to bottom.
//
// The layout follows chat-client's. In a window wider than 768 pixels, the
// messages fill the left and the compose box is a rail 320 pixels wide on
// the right. The rail is either open, its textarea as tall as the window,
// or closed, showing an "Open compose box" button and the keyboard help. It
// starts closed, and opens with the button or the c key. Escape closes it
// when the textarea is empty, so a draft stays where it is. After a send, the page
// that comes back has the rail open again. In a narrower window, the
// compose box is always open, below the messages.
//
// Ctrl+Enter (⌘+Enter on a Mac) sends, as chat-client does; plain Enter is
// a new line.
//
// New messages arrive on the conversation's stream as the page's own HTML,
// and the script appends them. The view follows them when it was at or near
// the newest message. When the connection drops, the browser
// reconnects by itself and says the last message it saw, so the server
// sends only what was missed. If the stream dies for good, the page
// reloads itself; if it dies again soon after, the page says so instead.
//
// The script styles what it arranges, with one style sheet of its own, so
// the server sends no CSS for it.
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

  // The breakpoint, chat-client's: a window at most this wide is narrow.
  var narrowQuery = window.matchMedia('(max-width:768px)');

  // The colors are chat-client's light palette, by its names there.
  var styleSheet = document.createElement('style');
  styleSheet.textContent = [
    '.messages:focus{outline:none}',
    '.compose-actions{display:flex;gap:8px}',

    // A narrow window: the messages, then the compose box below them.
    'html.layout-narrow body{margin:0 auto;height:100vh;display:flex;flex-direction:column}',
    'html.layout-narrow .messages{flex:1 1 auto;min-height:0;overflow-y:auto}',
    'html.layout-narrow .compose{flex:none;border-top:1px solid #ccc;padding:.5rem 0}',
    'html.layout-narrow .compose-closed{display:none}',
    'html.layout-narrow .compose form{display:flex;gap:.5rem;align-items:flex-end}',
    'html.layout-narrow .compose textarea{flex:1 1 auto;font:inherit;resize:vertical}',
    'html.layout-narrow .compose .help{margin:.25rem 0 0;color:#777;font-size:.85em}',

    // A wide window: the messages on the left, the compose rail on the right.
    'html.layout-wide body{max-width:none;margin:0;padding:10px 24px;box-sizing:border-box;height:100vh;' +
      'display:flex;flex-direction:row;align-items:stretch;gap:20px}',
    'html.layout-wide .messages{flex:1 1 auto;min-width:0;min-height:0;overflow-y:auto}',
    'html.layout-wide .compose{width:320px;flex:none;display:flex;flex-direction:column;min-height:0}',
    'html.layout-wide .compose-body{display:none;flex-direction:column;flex:1;min-height:0}',
    'html.layout-wide .compose.open .compose-body{display:flex}',
    'html.layout-wide .compose.open .compose-closed{display:none}',
    'html.layout-wide .compose form{margin:0;display:flex;flex-direction:column;flex:1;min-height:0}',
    'html.layout-wide .compose textarea{width:100%;flex:1;min-height:0;resize:vertical;box-sizing:border-box;' +
      'font-family:inherit;font-size:14px;padding:8px;background:#fafafa;color:#111;border:1px solid #e3e3ef}',
    'html.layout-wide .compose-actions{margin-top:8px}',
    'html.layout-wide .compose .help{font-size:12px;color:#999;margin:8px 0 0}',

    // The closed rail: its button and the keyboard help, as chat-client's.
    '.open-compose{font-size:13px;padding:4px 12px;background:#e7e7ff;color:#23235a;' +
      'border:1px solid #b9b9e0;border-radius:6px;cursor:pointer}',
    '.open-compose:hover{background:#d8d8ff}',
    '.keyhelp{margin-top:18px;font-size:13px;color:#444}',
    '.keyhelp-title{font-weight:bold;color:#333;margin-bottom:7px}',
    '.keyhelp-row{margin:5px 0}',
    '.keyhelp-key{display:inline-block;min-width:1.1em;text-align:center;padding:1px 6px;' +
      'font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;color:#333;background:#fff;' +
      'border:1px solid #ddd;border-bottom-width:2px;border-radius:4px;margin-right:7px;cursor:pointer}',
    '.keyhelp-key:hover{background:#f6f6fb;border-color:#b9b9e0}',
    '.keyhelp-key:active{background:#e7e7ff;border-bottom-width:1px;transform:translateY(1px)}',
  ].join('\n');
  document.head.appendChild(styleSheet);

  // The compose body holds the server's form and its help line; the Send
  // button sits in a row of actions under the textarea.
  var composeBody = document.createElement('div');
  composeBody.className = 'compose-body';
  var actions = document.createElement('div');
  actions.className = 'compose-actions';
  form.insertBefore(actions, send);
  actions.appendChild(send);
  compose.insertBefore(composeBody, form);
  composeBody.appendChild(form);
  composeBody.appendChild(help);
  box.rows = 3;
  box.placeholder = 'Write a message…  Markdown is supported, and longer posts are welcome.';

  messages.tabIndex = -1;

  function isNarrow() { return narrowQuery.matches; }

  function openCompose() {
    compose.classList.add('open');
    box.focus();
  }
  function closeCompose() {
    compose.classList.remove('open');
    messages.focus();
  }

  // Each key the keyboard help lists, with what it does. A key's button in
  // the help does the same.
  var shortcuts = [
    { key: 'c', label: 'compose', action: openCompose },
  ];

  var closedPanel = document.createElement('div');
  closedPanel.className = 'compose-closed';
  var openButton = document.createElement('button');
  openButton.type = 'button';
  openButton.className = 'open-compose';
  openButton.textContent = 'Open compose box';
  openButton.addEventListener('click', openCompose);
  closedPanel.appendChild(openButton);
  var keyhelp = document.createElement('div');
  keyhelp.className = 'keyhelp';
  var keyhelpTitle = document.createElement('div');
  keyhelpTitle.className = 'keyhelp-title';
  keyhelpTitle.textContent = 'Keyboard';
  keyhelp.appendChild(keyhelpTitle);
  shortcuts.forEach(function (shortcut) {
    var row = document.createElement('div');
    row.className = 'keyhelp-row';
    var keyButton = document.createElement('button');
    keyButton.type = 'button';
    keyButton.className = 'keyhelp-key';
    keyButton.textContent = shortcut.key;
    keyButton.title = shortcut.label;
    keyButton.addEventListener('click', shortcut.action);
    row.appendChild(keyButton);
    row.appendChild(document.createTextNode(' ' + shortcut.label));
    keyhelp.appendChild(row);
  });
  closedPanel.appendChild(keyhelp);
  compose.appendChild(closedPanel);

  // A shortcut key works when no text field has the focus and no modifier
  // is held, as in chat-client.
  document.addEventListener('keydown', function (e) {
    var focused = document.activeElement;
    if (focused && (focused.tagName === 'TEXTAREA' || focused.tagName === 'INPUT' || focused.isContentEditable)) return;
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    for (var i = 0; i < shortcuts.length; i++) {
      if (shortcuts[i].key === e.key) {
        e.preventDefault();
        shortcuts[i].action();
        return;
      }
    }
  });

  function applyLayout() {
    var root = document.documentElement;
    root.classList.toggle('layout-narrow', isNarrow());
    root.classList.toggle('layout-wide', !isNarrow());
  }
  applyLayout();
  narrowQuery.addEventListener('change', applyLayout);

  // A send reloads the page, and the rail opens again on the page that comes
  // back, as chat-client's stays open after a send. This tab's storage
  // carries that across the reload.
  var OPEN_AFTER_SEND_KEY = 'gopher-roc compose open after send';
  function takeOpenAfterSend() {
    try {
      var wanted = sessionStorage.getItem(OPEN_AFTER_SEND_KEY) !== null;
      sessionStorage.removeItem(OPEN_AFTER_SEND_KEY);
      return wanted;
    } catch (err) {
      return false;
    }
  }
  if (takeOpenAfterSend() || isNarrow()) {
    openCompose();
  } else {
    messages.focus();
  }

  function scrollToNewest() { messages.scrollTop = messages.scrollHeight; }
  scrollToNewest();
  // Images lay out late; the newest message stays in view once they have.
  window.addEventListener('load', scrollToNewest);

  // One send per page: a second Ctrl+Enter while the first is on its way would
  // post the message twice. A page shown again from the back button's cache
  // may send again.
  var sending = false;
  form.addEventListener('submit', function () {
    sending = true;
    try {
      sessionStorage.setItem(OPEN_AFTER_SEND_KEY, '1');
    } catch (err) {
      // With no storage, the page that comes back starts with the rail closed.
    }
  });
  window.addEventListener('pageshow', function () { sending = false; });
  box.addEventListener('keydown', function (e) {
    if (e.isComposing) return;
    if (e.key === 'Escape' && !isNarrow() && box.value.trim() === '') {
      e.preventDefault();
      closeCompose();
      return;
    }
    if (e.key !== 'Enter' || !(e.ctrlKey || e.metaKey)) return;
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
