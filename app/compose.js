// THE CONVERSATION PAGE'S SCRIPT: the two panes and the compose box's keys.
//
// app/Page.roc builds the markup (`.messages`, then `.compose` holding the
// form and its keyboard help); app/ComposeScript.roc serves this file, its
// bytes' one home being this file. The page works without it: the form
// posts, and the messages read top to bottom. With it:
//
// - the messages fill the window above a fixed compose area, and open
//   scrolled to the newest;
// - the textarea has the focus;
// - Ctrl+Enter (⌘+Enter on a Mac) sends, as the old chat-client's box
//   does, and plain Enter is a new line (and a key while an input method is
//   composing a character is the input method's);
// - each message added after the page was drawn, by any tab or by curl,
//   arrives on the conversation's stream (`.messages`' data-stream, after
//   the data-after messages it shows) as the page's own HTML, and is
//   appended; the view follows it only when the newest was in view, as
//   chat-client's does. The browser's EventSource reconnects by itself,
//   saying the last message it saw, so none is missed or shown twice.
//
// It styles the elements it arranges itself (`.style`), so the server
// sends no CSS for them.
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

  // Whether the newest message's bottom is in view, read before a new one
  // is appended below it.
  function newestInView() {
    var newest = messages.lastElementChild;
    if (!newest) return true;
    return newest.getBoundingClientRect().bottom <= messages.getBoundingClientRect().bottom + 1;
  }

  var events = new EventSource(stream + '?after=' + after);
  events.onmessage = function (e) {
    var follow = newestInView();
    var empty = messages.querySelector('.empty');
    if (empty) empty.remove();
    messages.insertAdjacentHTML('beforeend', e.data);
    if (follow) scrollToNewest();
  };
  // A page restored from the back button's cache has a stream that was
  // torn down; chat-client reloads it, and so does this.
  window.addEventListener('pageshow', function (e) { if (e.persisted) location.reload(); });
})();
