// This script runs on a conversation page, which app/ConversationPage.roc
// builds and app/Script.roc serves. It gives each message its actions:
// reacting with an emoji, and editing the viewer's own, as chat-client's
// messages did (js/message.js, js/chat_reactions.js and js/chat.js's
// doEdit). It runs after compose.js and feed.js, and feed.js hands it each
// message the stream brings, or brings again (Actions.dress).
//
// The server draws everything a message shows, its reactions and its edit
// included, so this script only styles what it finds and sends what the
// reader asks for. A reaction's button names its reactors' ids
// (data-reactors); the viewer's own are highlighted, and a click takes the
// viewer's reaction back, or adds it. The "react" button, or the `:` key
// on the selected message, opens a small picker of emojis. Each reaction is
// a POST to the messages pane's data-react (`msg`, `emoji`, `on`), and is
// never shown before the server has it: the stream sends the message again,
// drawn with its reactions as they are now, and feed.js puts it in place.
//
// An edit is a new message whose first line is "Edit of " and the
// reference of the message it edits, as chat-client's were. The "edit"
// button, on the viewer's own messages, or the `e` key on the selected
// one, reads the message's markdown as written (the pane's data-raw, with
// `?message=<n>`) and loads the box with that line, a blank line and the
// markdown, the caret after the blank line. Sending it is the box's own
// send. The server marks the original edited and the stream redraws it.
//
// In a narrow window (chrome.js's layout-narrow), a phone's, the buttons, the
// reactions and the picker's emojis are larger, for a finger, and the
// picker opens across the window's width under the message.
(function () {
  'use strict';
  var messages = document.querySelector('.messages');
  if (!messages) throw new Error('actions.js: the page has no .messages');
  if (!window.Keys || !window.Compose) throw new Error('actions.js: compose.js runs first, and gives Keys and Compose');
  var viewer = messages.getAttribute('data-viewer');
  var reactUrl = messages.getAttribute('data-react');
  var rawUrl = messages.getAttribute('data-raw');
  if (!viewer || !reactUrl || !rawUrl) {
    throw new Error('actions.js: .messages has no data-viewer, no data-react or no data-raw');
  }

  // The picker's emojis, a few of chat-client's (js/chat_emoji.js), in its
  // order.
  var EMOJIS = ['👍', '❤️', '😂', '🎉', '🙏', '👀', '✅', '🤔', '😮', '😢', '🔥', '💯'];

  var s = document.createElement('style');
  s.textContent = [
    '.message .actions { margin-left: 6px; }',
    '.message .actions button { font: inherit; font-size: 11px; color: var(--cc-muted-fg); background: none;' +
      ' border: none; padding: 0 3px; cursor: pointer; }',
    '.message .actions button:hover { color: var(--cc-accent); text-decoration: underline; }',
    '.reaction-strip { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 6px; }',
    '.reaction-chip { font-size: 12px; line-height: 1.2; padding: 2px 7px; border-radius: 10px; cursor: pointer;' +
      ' background: var(--cc-bg); color: var(--cc-fg); border: 1px solid var(--cc-border); }',
    '.reaction-chip:hover { border-color: var(--cc-accent); }',
    '.reaction-chip.mine { background: var(--cc-accent-soft-bg); border-color: var(--cc-accent); }',
    '.edited-note { font-size: 12px; color: var(--cc-muted-fg); margin: 0 0 4px; }',
    '.edited-original > summary { font-size: 11px; color: var(--cc-muted-fg); cursor: pointer; }',
    '.edited-markdown { font-size: 11px; color: var(--cc-soft-muted-fg); white-space: pre-wrap; overflow-wrap: anywhere;' +
      ' border-left: 3px solid var(--cc-border); padding: 2px 0 2px 8px; margin-top: 4px; }',
    '.reaction-picker { position: fixed; z-index: 10; display: flex; flex-wrap: wrap; gap: 2px; max-width: 220px;' +
      ' padding: 6px; border-radius: 8px; border: 1px solid var(--cc-border); background: var(--cc-card-bg);' +
      ' box-shadow: 0 4px 12px rgba(0, 0, 0, 0.25); }',
    '.reaction-picker button { font-size: 18px; background: none; border: none; padding: 2px 4px; cursor: pointer; border-radius: 4px; }',
    '.reaction-picker button:hover { background: var(--cc-accent-soft-bg); }',
    'html.layout-narrow .message .actions button { font-size: 13px; padding: 6px 8px; }',
    'html.layout-narrow .reaction-chip { font-size: 14px; padding: 5px 10px; border-radius: 14px; }',
    'html.layout-narrow .reaction-picker { max-width: none; gap: 4px; }',
    'html.layout-narrow .reaction-picker button { font-size: 24px; padding: 6px 8px; }',
    '.action-failed { position: fixed; z-index: 11; bottom: 16px; left: 50%; transform: translateX(-50%);' +
      ' padding: .5rem .75rem; border-radius: 6px; background: var(--cc-lost-bg); color: var(--cc-lost-fg); }',
  ].join('\n');
  document.head.appendChild(s);

  // The message's number, from its id, msg-<n>.
  function numberOf(article) { return article.id.replace(/^msg-/, ''); }
  function isMine(article) { return article.getAttribute('data-author') === viewer; }
  function reactorsOf(chip) { return (chip.getAttribute('data-reactors') || '').split('-'); }
  function emojiOf(chip) {
    var glyph = chip.querySelector('.reaction-emoji');
    return glyph ? glyph.textContent : '';
  }
  // Whether the viewer has reacted to `article` with `emoji`.
  function reacted(article, emoji) {
    var chips = article.querySelectorAll('.reaction-chip');
    for (var i = 0; i < chips.length; i++) {
      if (emojiOf(chips[i]) === emoji) return reactorsOf(chips[i]).indexOf(viewer) >= 0;
    }
    return false;
  }

  function showFailure(words) {
    var old = document.querySelector('.action-failed');
    if (old) old.remove();
    var notice = document.createElement('p');
    notice.className = 'action-failed';
    notice.textContent = words;
    document.body.appendChild(notice);
    setTimeout(function () { notice.remove(); }, 4000);
  }

  // The viewer's reaction `emoji` to `article`, added, or taken back when
  // it is there.
  function toggle(article, emoji) {
    var form = new URLSearchParams();
    form.set('msg', numberOf(article));
    form.set('emoji', emoji);
    form.set('on', reacted(article, emoji) ? '0' : '1');
    fetch(reactUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
    }).then(function (r) {
      if (r.ok) return;
      return r.text().then(function (text) { showFailure('Reaction refused: ' + text.trim()); });
    }).catch(function () { showFailure('Reaction failed: the server did not answer.'); });
  }

  var picker = null;
  function closePicker() {
    if (picker) picker.remove();
    picker = null;
  }
  function openPicker(article) {
    closePicker();
    picker = document.createElement('div');
    picker.className = 'reaction-picker';
    EMOJIS.forEach(function (emoji) {
      var b = document.createElement('button');
      b.type = 'button';
      b.textContent = emoji;
      b.addEventListener('click', function () {
        closePicker();
        toggle(article, emoji);
      });
      picker.appendChild(b);
    });
    var box = article.getBoundingClientRect();
    if (document.documentElement.classList.contains('layout-narrow')) {
      picker.style.left = '8px';
      picker.style.right = '8px';
    } else {
      picker.style.left = Math.max(8, Math.min(box.left, window.innerWidth - 240)) + 'px';
    }
    document.body.appendChild(picker);
    var height = picker.getBoundingClientRect().height;
    picker.style.top = Math.max(8, Math.min(box.top + 20, window.innerHeight - height - 8)) + 'px';
  }
  document.addEventListener('click', function (e) {
    if (picker && !picker.contains(e.target) && !(e.target.closest && e.target.closest('.react-open'))) closePicker();
  });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closePicker(); });

  // Loads the box with an edit of `article`, the viewer's own.
  function edit(article) {
    if (!isMine(article)) return;
    var ref = article.querySelector('header .ref');
    if (!ref) return;
    fetch(rawUrl + '?message=' + numberOf(article)).then(function (r) {
      return r.text().then(function (text) {
        if (!r.ok) {
          showFailure('The message could not be read: ' + text.trim());
          return;
        }
        var first = 'Edit of ' + ref.textContent + '\n\n';
        Compose.load(first + text, first.length);
      });
    }).catch(function () { showFailure('The message could not be read: the server did not answer.'); });
  }

  // What the script adds to a message the server drew: its action buttons,
  // and the viewer's own reactions marked.
  function dress(article) {
    var chips = article.querySelectorAll('.reaction-chip');
    for (var i = 0; i < chips.length; i++) {
      var mine = reactorsOf(chips[i]).indexOf(viewer) >= 0;
      chips[i].type = 'button';
      chips[i].classList.toggle('mine', mine);
      chips[i].title = mine ? 'Click to take your reaction back' : 'Click to react too';
    }
    var header = article.querySelector('header');
    if (!header || header.querySelector('.actions')) return;
    var actions = document.createElement('span');
    actions.className = 'actions';
    var react = document.createElement('button');
    react.type = 'button';
    react.className = 'react-open';
    react.textContent = 'react';
    react.title = 'React with an emoji (:)';
    actions.appendChild(react);
    if (isMine(article)) {
      var editButton = document.createElement('button');
      editButton.type = 'button';
      editButton.className = 'edit-open';
      editButton.textContent = 'edit';
      editButton.title = 'Load this message into the compose box as an edit (e)';
      actions.appendChild(editButton);
    }
    header.appendChild(actions);
  }

  messages.addEventListener('click', function (e) {
    var article = e.target.closest && e.target.closest('.message');
    if (!article) return;
    var chip = e.target.closest('.reaction-chip');
    if (chip) { toggle(article, emojiOf(chip)); return; }
    if (e.target.closest('.react-open')) { openPicker(article); return; }
    if (e.target.closest('.edit-open')) edit(article);
  });

  function selectedMessage() { return messages.querySelector('.message.selected'); }
  Keys.register({ key: ':', label: 'react to the selected message', run: function () {
    var article = selectedMessage();
    if (article) openPicker(article);
  } });
  Keys.register({ key: 'e', label: 'edit the selected message, if yours', run: function () {
    var article = selectedMessage();
    if (article) edit(article);
  } });

  var drawn = messages.querySelectorAll('.message');
  for (var j = 0; j < drawn.length; j++) dress(drawn[j]);
  window.Actions = { dress: dress };
})();
