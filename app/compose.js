// This script runs on a conversation page, which app/ConversationPage.roc
// builds and app/Script.roc serves.
//
// The layout follows chat-client's. In a window wider than 768 pixels, the
// messages are on the left and the compose box is a rail 320 pixels wide on
// the right. The rail is either open, its textarea as tall as the window,
// or closed, showing an "Open compose box" button and the keyboard help. It
// starts closed, and opens with the button or the c key. Escape in the
// textarea closes it when the textarea is empty, and does nothing while it
// holds text, as chat-client's did (js/chat_compose.js); the ✕ button at the
// open rail's top closes it whatever it holds, as chat-client's ▾ did, the
// text left in the closed box, there when it opens again. Nothing is kept
// past the page: there are no drafts (Steve, 2026-11-20: "Back the whole
// drafts feature out. ... Using the same button to open the compose box and
// a draft is not good UI. I may not want the draft."). In a narrower
// window, a phone's, the compose box is a bar below the messages, as
// chat-client's was (js/chat_responsive.js): it starts open, but not focused,
// so the phone's keyboard doesn't rise over the messages until a tap on the
// box (or a quote) asks for it; its ▾ button
// closes it to the "Open compose box" button, as the ✕ does, and the keyboard help and the
// help line, which a phone has no keys for, are left out.
//
// Ctrl+Enter (⌘+Enter on a Mac) sends, as chat-client does; plain Enter is
// a new line. The Send button sends too, which is how a phone sends.
// emoji.js, which runs next, autocompletes an emoji's `:name` in the box,
// and while its menu is open, Enter and Tab take the emoji instead.
//
// A send stays on the page, as chat-client's did (js/chat_compose.js). The
// script posts the form to the conversation's `/send` (the form's
// data-send), and the box and its buttons are off until the server answers,
// the status line saying "Sending…". The server answers a 201 with the
// message's HTML once the message is stored; then the box empties and comes
// back on. The message itself appears through the stream, as everyone else
// sees it, and when it arrives there the status line says it was sent,
// linking to it. A refusal shows the server's own words and keeps the
// draft. With no answer in 3 seconds, the status line says "Still sending…"
// and Send stays off, since the first post may yet be stored: a retry then
// could post the message twice. The box is read-only meanwhile, so its text
// can still be selected and copied. With no answer in 15 seconds the script
// asks whether the server answers at all, a GET of palette.js that is never
// cached, given 5 seconds, and asks again every 15 seconds while the send
// waits; the status line says plainly which it is: the server answers but
// hasn't stored the message yet, or the server can't be reached. Send comes
// back only with the send's own answer: a 201, however late, empties the
// box as usual; a refusal (any answer that is not a 2xx) keeps the draft
// and shows the server's words; and a connection that fails outright keeps
// the draft and says, in chat-client's dialog, that the message may or may
// not have been stored, to look for it before sending again: a connection
// cut after the server read the post leaves no way to tell. (chat-client
// gave up waiting at 3 seconds and asked for a retry while the first post
// was still on its way, telling the writer afterwards, by its client id's
// echo on the stream, that the message had arrived after all; this
// departs from it, on purpose: nothing is offered to send again while the
// first post may still be stored.)
//
// The page's keys are one table, Keys, here: each key a feature registers
// is listed in the closed rail's keyboard help, as a button that does what
// the key does, so the help lists exactly the keys that work. feed.js
// registers the keys that move between messages.
//
// An image goes into a message as chat-client's compose box puts one there.
// The Upload button picks a file, and an image pasted into the box, or
// dropped onto the open compose box, is sent the same way; a file dragged
// over it outlines the box. A large photo is first shrunk in the browser: its longest
// side to 2048 pixels, a JPEG over 1.5 MB re-encoded, a PNG scaled and kept
// a PNG, and a GIF or WebP sent as it is. The original is sent whenever the
// shrunk one is no smaller, or shrinking fails or takes over 15 seconds. One
// upload runs at a time, its progress shown, and it is given up after five
// minutes. The server keeps the image in the conversation and answers its
// URL, and the script puts an <img> of it at the cursor. The form names where
// to upload (data-upload) and the most an image may be (data-image-byte-limit).
//
// The messages pane, its stream and the newest message's place in view are
// feed.js's; this script runs before it, so the panes are laid out by the
// time feed.js first scrolls to the newest message, and Keys and Compose
// are there for feed.js to use.
//
// The script styles what it arranges, with one style sheet of its own, so
// the server sends no CSS for it. Its colours are palette.js's.
(function () {
  'use strict';
  var layout = document.querySelector('.layout');
  var messages = document.querySelector('.messages');
  var compose = document.querySelector('.compose');
  var form = compose && compose.querySelector('form');
  var box = form && form.querySelector('textarea');
  var send = form && form.querySelector('button');
  var help = compose && compose.querySelector('.help');
  if (!layout || !messages || !box || !send || !help) {
    throw new Error('compose.js: the page has no .layout, no .messages, or no .compose with a form, its textarea, its button and .help');
  }

  if (!window.Viewport) throw new Error('compose.js: chrome.js runs first, and gives Viewport');

  // The colours are palette.js's, by chat-client's names.
  var styleSheet = document.createElement('style');
  styleSheet.textContent = [
    '.compose-actions{display:flex;gap:8px}',
    '.compose-status{font-size:12px;color:var(--cc-muted-fg);min-height:16px;margin-top:6px}',
    '.compose textarea{box-sizing:border-box;font-family:inherit;font-size:14px;padding:8px;border-radius:8px;' +
      'background:var(--cc-card-bg);color:var(--cc-fg);border:1px solid var(--cc-input-border)}',
    '.compose textarea:read-only{opacity:.6}',
    '.compose textarea:focus{outline:none;border-color:var(--cc-accent);box-shadow:0 0 0 1px var(--cc-accent)}',
    // A file dragged over the open box: a dashed accent outline and a
    // tinted textarea, until it is dropped or leaves.
    '.compose.compose-drop-over textarea{border:2px dashed var(--cc-accent);background:var(--cc-accent-soft-bg)}',
    // Send is the primary action, in the accent; Upload is drawn as
    // panel.js draws a page's buttons.
    '.compose-actions button{font-family:inherit;font-size:13px;padding:4px 12px;border-radius:6px;cursor:pointer}',
    '.compose-send{background:var(--cc-accent);color:var(--cc-bg);border:1px solid var(--cc-accent)}',
    '.compose-send:hover:not(:disabled){background:var(--cc-accent-hover);border-color:var(--cc-accent-hover)}',
    '.compose-upload{background:var(--cc-mine-bg);color:var(--cc-search-tok-fg);border:1px solid var(--cc-quote-border)}',
    '.compose-upload:hover:not(:disabled){background:var(--cc-accent-soft-hov)}',
    '.compose-actions button:disabled{opacity:.5;cursor:default}',
    '.compose .help{font-size:12px;color:var(--cc-soft-muted-fg)}',

    // A narrow window: the messages, then the compose box below them.
    'html.layout-narrow .layout{flex-direction:column;gap:8px}',
    'html.layout-narrow .compose{flex:none;max-height:45vh;border-top:1px solid var(--cc-border);padding-top:4px}',
    'html.layout-narrow .compose-body{display:none}',
    'html.layout-narrow .compose.open .compose-body{display:block}',
    'html.layout-narrow .compose.open .compose-closed{display:none}',
    'html.layout-narrow .compose form{display:flex;gap:.5rem;align-items:flex-end}',
    'html.layout-narrow .compose textarea{flex:1 1 auto;min-height:80px;max-height:25vh;resize:none}',
    'html.layout-narrow .compose-actions{flex-direction:column}',
    'html.layout-narrow .compose-actions button{padding:8px 12px}',
    'html.layout-narrow .compose .help, html.layout-narrow .keyhelp{display:none}',
    '.compose-collapse{display:none}',
    'html.layout-narrow .compose-collapse{display:flex;justify-content:flex-end}',
    '.compose-collapse button{background:none;border:none;color:var(--cc-muted-fg);font-size:18px;' +
      'cursor:pointer;padding:2px 8px;line-height:1}',
    // The wide rail's close button, over the textarea's top-right corner,
    // so the textarea's top lines up with the message pane's. The textarea
    // keeps 32px on its right, the button's 26px and a gap, so typed text
    // never runs under it.
    '.compose-hide{display:none}',
    'html.layout-wide .compose-body{position:relative}',
    'html.layout-wide .compose-hide{display:block;position:absolute;top:3px;right:3px;z-index:1}',
    'html.layout-wide .compose textarea{padding-right:32px}',
    '.compose-hide button{background:none;border:none;color:var(--cc-muted-fg);font-size:14px;' +
      'cursor:pointer;padding:2px 6px;line-height:1;border-radius:4px}',
    '.compose-hide button:hover{color:var(--cc-fg);background:var(--cc-accent-soft-bg)}',

    // A wide window: the messages on the left, the compose rail on the right.
    'html.layout-wide .layout{flex-direction:row;align-items:stretch}',
    'html.layout-wide .compose{width:320px;flex:none;display:flex;flex-direction:column;min-height:0}',
    'html.layout-wide .compose-body{display:none;flex-direction:column;flex:1;min-height:0}',
    'html.layout-wide .compose.open .compose-body{display:flex}',
    'html.layout-wide .compose.open .compose-closed{display:none}',
    'html.layout-wide .compose form{margin:0;display:flex;flex-direction:column;flex:1;min-height:0}',
    'html.layout-wide .compose textarea{width:100%;flex:1;min-height:0;resize:vertical}',
    'html.layout-wide .compose-actions{margin-top:8px}',
    'html.layout-wide .compose .help{margin:8px 0 0}',

    // The closed rail: its button and the keyboard help, as chat-client's.
    // The button is a call to action (Steve, 2026-11-20: "green
    // (call-to-action color), and 5% bigger"): 13.65px words and padding of
    // 4.2px by 12.6px, 5% over Upload's 13px and 4px by 12px.
    '.open-compose{font-family:inherit;font-size:13.65px;padding:4.2px 12.6px;background:var(--cc-go-bg);color:var(--cc-go-fg);' +
      'border:1px solid var(--cc-go-bg);border-radius:6px;cursor:pointer}',
    '.open-compose:hover{background:var(--cc-go-hover-bg);border-color:var(--cc-go-hover-bg)}',
    '.keyhelp{margin-top:18px;font-size:13px;color:var(--cc-body-muted-fg)}',
    '.keyhelp-title{font-weight:bold;color:var(--cc-meta-fg);margin-bottom:7px}',
    '.keyhelp-row{margin:5px 0}',
    '.keyhelp-nav{margin-top:14px}',
    // The help is longer than a short window: the closed rail scrolls, so
    // its last rows are never cut off.
    'html.layout-wide .compose-closed{flex:1 1 auto;min-height:0;overflow-y:auto}',
    '.keyhelp-key{display:inline-block;min-width:1.1em;text-align:center;padding:1px 6px;' +
      'font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;color:var(--cc-meta-fg);background:var(--cc-bg);' +
      'border:1px solid var(--cc-border);border-bottom-width:2px;border-radius:4px;margin-right:7px;cursor:pointer}',
    '.keyhelp-key:hover{background:var(--cc-quote-bg);border-color:var(--cc-quote-border)}',
    '.keyhelp-key:active{background:var(--cc-mine-bg);border-bottom-width:1px;transform:translateY(1px)}',

    // The "host may be down" dialog, chat-client's.
    '.compose-alert{max-width:90vw;border:1px solid var(--cc-dialog-border);background:var(--cc-bg);color:var(--cc-fg);' +
      'border-radius:8px;padding:18px 20px}',
    '.compose-alert::backdrop{background:var(--cc-backdrop)}',
    '.compose-alert p{margin:0 0 14px}',
    '.compose-alert button{padding:5px 16px}',
  ].join('\n');
  document.head.appendChild(styleSheet);

  // The compose body holds the server's form, the hidden file picker, a
  // status line for uploads, and the help line. The Send and Upload buttons
  // sit in a row of actions under the textarea.
  var composeBody = document.createElement('div');
  composeBody.className = 'compose-body';
  var actions = document.createElement('div');
  actions.className = 'compose-actions';
  form.insertBefore(actions, send);
  actions.appendChild(send);
  send.className = 'compose-send';
  var uploadButton = document.createElement('button');
  uploadButton.type = 'button';
  uploadButton.className = 'compose-upload';
  uploadButton.textContent = 'Upload';
  actions.appendChild(uploadButton);
  var picker = document.createElement('input');
  picker.type = 'file';
  picker.accept = 'image/png,image/jpeg,image/gif,image/webp';
  picker.hidden = true;
  var status = document.createElement('div');
  status.className = 'compose-status';
  compose.insertBefore(composeBody, form);
  var collapse = document.createElement('div');
  collapse.className = 'compose-collapse';
  var collapseButton = document.createElement('button');
  collapseButton.type = 'button';
  collapseButton.textContent = '▾';
  collapseButton.setAttribute('aria-label', 'Close the compose box');
  collapseButton.addEventListener('click', function () { closeCompose(); });
  collapse.appendChild(collapseButton);
  composeBody.appendChild(collapse);
  var hide = document.createElement('div');
  hide.className = 'compose-hide';
  var hideButton = document.createElement('button');
  hideButton.type = 'button';
  hideButton.textContent = '✕';
  hideButton.title = 'Close the compose box';
  hideButton.setAttribute('aria-label', 'Close the compose box');
  hideButton.addEventListener('click', function () { closeCompose(); });
  hide.appendChild(hideButton);
  composeBody.appendChild(hide);
  composeBody.appendChild(form);
  composeBody.appendChild(picker);
  composeBody.appendChild(status);
  composeBody.appendChild(help);
  box.rows = 3;
  // The help line names both platforms' send keys, as the server can't tell
  // which one reads it; the script keeps only this one's.
  var BOTH_KEYS = 'Ctrl/⌘-Enter';
  if (help.textContent.indexOf(BOTH_KEYS) < 0) throw new Error('compose.js: the help line names no ' + BOTH_KEYS);
  var onMac = /Mac|iPhone|iPad|iPod/.test((navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || '');
  help.textContent = help.textContent.replace(BOTH_KEYS, onMac ? '⌘-Enter' : 'Ctrl-Enter');

  messages.tabIndex = -1;

  function isNarrow() { return Viewport.isNarrow(); }

  function openCompose() {
    compose.classList.add('open');
    box.focus();
  }
  // Closed, its text left in the box, as chat-client's closeCompose did.
  function closeCompose() {
    compose.classList.remove('open');
    messages.focus();
  }

  // The closed rail's button names the c key where there are keys.
  function refreshOpenButton() {
    openButton.textContent = 'Open compose box' + (isNarrow() ? '' : ' (c)');
  }

  var closedPanel = document.createElement('div');
  closedPanel.className = 'compose-closed';
  var openButton = document.createElement('button');
  openButton.type = 'button';
  openButton.className = 'open-compose';
  openButton.addEventListener('click', openCompose);
  closedPanel.appendChild(openButton);
  var keyhelp = document.createElement('div');
  keyhelp.className = 'keyhelp';
  var keyhelpTitle = document.createElement('div');
  keyhelpTitle.className = 'keyhelp-title';
  keyhelpTitle.textContent = 'Keyboard';
  keyhelp.appendChild(keyhelpTitle);
  var keyhelpRows = document.createElement('div');
  keyhelp.appendChild(keyhelpRows);
  // The navigation keys (arrows, Home, End, PgUp, PgDn) are the most
  // guessable, so they come last, under their own heading.
  var keyhelpNav = document.createElement('div');
  keyhelpNav.className = 'keyhelp-nav';
  keyhelpNav.hidden = true;
  var keyhelpNavTitle = document.createElement('div');
  keyhelpNavTitle.className = 'keyhelp-title';
  keyhelpNavTitle.textContent = 'Navigation';
  keyhelpNav.appendChild(keyhelpNavTitle);
  keyhelp.appendChild(keyhelpNav);
  closedPanel.appendChild(keyhelp);
  compose.appendChild(closedPanel);

  // The page's one key table. Keys.register({ key, cap, label, run, aliases, group })
  // takes the key's name (KeyboardEvent.key), what its button in the help
  // shows (the name, when no cap is given), what it does, the function that
  // does it, and any other keys that do the same, and adds one row to the
  // help, the aliases named after the label in parentheses; `group:
  // 'navigation'` puts the row under the Navigation heading at the end, in
  // the order its keys are registered, which is theirs. The other rows sort
  // here, whenever a key is registered (Steve, 2026-11-20: "err on the side
  // of alphabetizing things that have no clear order"): the letter keys
  // alphabetically, then `/` (search, essential), then the other symbols
  // (`+`, `:`: "not as essential as the other keys and pretty easy to
  // guess"), by their key. A key registered twice is an
  // error, so two features never both think they own one. A key works when
  // no text field has the focus and no modifier is held, as in chat-client.
  window.Keys = (function () {
    var byKey = Object.create(null);
    function register(entry) {
      if (!entry || !entry.key || !entry.label || typeof entry.run !== 'function') {
        throw new Error('Keys.register: a key, a label and a run');
      }
      var keys = [entry.key].concat(entry.aliases || []);
      keys.forEach(function (key) {
        if (byKey[key]) throw new Error('Keys.register: "' + key + '" is registered twice');
        byKey[key] = entry;
      });
      var row = document.createElement('div');
      row.className = 'keyhelp-row';
      var keyButton = document.createElement('button');
      keyButton.type = 'button';
      keyButton.className = 'keyhelp-key';
      keyButton.textContent = entry.cap || entry.key;
      keyButton.title = entry.label;
      keyButton.addEventListener('click', function () { entry.run(); });
      row.appendChild(keyButton);
      var aliases = entry.aliases && entry.aliases.length ? ' (also ' + entry.aliases.join(' or ') + ')' : '';
      row.appendChild(document.createTextNode(' ' + entry.label + aliases));
      if (entry.group === 'navigation') {
        keyhelpNav.appendChild(row);
        keyhelpNav.hidden = false;
      } else if (entry.group) {
        throw new Error('Keys.register: "' + entry.group + '" is no group');
      } else {
        row.helpOrder = helpOrder(entry.key);
        var after = null;
        for (var next = keyhelpRows.firstChild; next; next = next.nextSibling) {
          if (next.helpOrder > row.helpOrder) { after = next; break; }
        }
        keyhelpRows.insertBefore(row, after);
      }
    }
    // A row's place in the help: a letter, then `/`, then any other key.
    function helpOrder(key) {
      var rank = /^[a-z]$/i.test(key) ? '0' : key === '/' ? '1' : '2';
      return rank + key;
    }
    document.addEventListener('keydown', function (e) {
      var focused = document.activeElement;
      if (focused && (focused.tagName === 'TEXTAREA' || focused.tagName === 'INPUT' || focused.isContentEditable)) return;
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      var entry = byKey[e.key];
      if (!entry) return;
      e.preventDefault();
      entry.run();
    });
    return { register: register };
  })();
  Keys.register({ key: 'c', label: 'compose a message', run: openCompose });

  Viewport.onChange(refreshOpenButton);
  if (isNarrow()) compose.classList.add('open');
  messages.focus();

  var sendUrl = form.getAttribute('data-send');
  if (!sendUrl) throw new Error('compose.js: the form has no data-send');
  // The status line is muted, the neutral colour, but for an error's words.
  var ERROR = 'var(--cc-error)';
  // The last "✓ sent" notice's link, which typing clears while the status
  // line still shows it.
  var sentLink = null;
  var STILL_SENDING_MS = 3000;
  var NO_ANSWER_MS = 15000;
  var SERVER_CHECK_MS = 15000;
  var SERVER_CHECK_PATIENCE_MS = 5000;

  // The one send on its way, if any: its timer. A second send waits for its
  // answer, so one Ctrl+Enter pressed twice, or a retry while the network is
  // slow, never posts the message twice.
  var pending = null;
  // The ids of the messages this page sent whose arrival on the stream is
  // still to be noticed.
  var awaitingArrival = Object.create(null);

  // The page's place and topic, as the messages pane names them (data-place:
  // `#channel`, a DM's other human, or the viewer on their own DM;
  // data-topic), which the placeholder and the sent notice name.
  var place = messages.getAttribute('data-place');
  var topic = messages.getAttribute('data-topic');
  if (!place || !topic) throw new Error('compose.js: .messages has no data-place or no data-topic');

  // The drafts build of 2026-11-20 kept unsent text in this browser under
  // 'roc-chat drafts', shared by whoever signs in here and kept past sign-out;
  // drafts are gone, so their leftover is removed. Delete this line once
  // every browser that ran that build has loaded a page since (2026-12-20).
  try { localStorage.removeItem('roc-chat drafts'); } catch (e) { /* No storage: nothing kept. */ }

  // The box and its buttons, on or off by what is on its way: while a send
  // is, all of them are off; while an upload is, Send and Upload are, so a
  // message never goes without the image being put in it. Send is off too
  // while the box holds nothing but space, so there is nothing to refuse.
  function refreshControls() {
    refreshOpenButton();
    box.readOnly = !!pending;
    send.disabled = !!pending || uploading || box.value.trim() === '';
    uploadButton.disabled = !!pending || uploading;
  }
  function settle() {
    clearTimeout(pending.timer);
    clearTimeout(pending.checkTimer);
    pending = null;
    status.textContent = '';
    status.style.color = '';
    refreshControls();
  }

  function showAlert(said) {
    var dialog = document.createElement('dialog');
    dialog.className = 'compose-alert';
    var p = document.createElement('p');
    p.textContent = said;
    var ok = document.createElement('button');
    ok.type = 'button';
    ok.textContent = 'OK';
    ok.addEventListener('click', function () { dialog.close(); });
    dialog.appendChild(p);
    dialog.appendChild(ok);
    dialog.addEventListener('close', function () { dialog.remove(); box.focus(); });
    document.body.appendChild(dialog);
    dialog.showModal();
  }
  // No answer yet: the send may still be stored, so the draft stays locked.
  function stillSending(mine) {
    if (pending !== mine) return;
    status.textContent = 'Still sending…';
  }
  // Long with no answer: whether the server answers anything, said plainly,
  // asked again until the send is answered.
  var pingScript = document.querySelector('script[src$="/palette.js"]');
  if (!pingScript) throw new Error('compose.js: the page loads no palette.js, which the server check asks for');
  var pingUrl = pingScript.src;
  function checkServer(mine) {
    if (pending !== mine) return;
    var waited = Math.round((Date.now() - mine.started) / 1000);
    var kept = ' Send stays off until the server answers, so the message is never posted twice.';
    function say(words) {
      if (pending !== mine) return;
      status.style.color = ERROR;
      status.textContent = words + kept;
      mine.checkTimer = setTimeout(function () { checkServer(mine); }, SERVER_CHECK_MS);
    }
    var aborter = typeof AbortController === 'function' ? new AbortController() : null;
    var giveUp = setTimeout(function () { if (aborter) aborter.abort(); }, SERVER_CHECK_PATIENCE_MS);
    fetch(pingUrl, { cache: 'no-store', signal: aborter ? aborter.signal : undefined }).then(function (r) {
      clearTimeout(giveUp);
      say(r.ok
        ? 'No answer to your send after ' + waited + ' seconds, though the server is up: it may still be storing it.'
        : 'No answer to your send after ' + waited + ' seconds, and the server answers ' + r.status + ' to a check.');
    }, function () {
      clearTimeout(giveUp);
      say('No answer to your send after ' + waited + ' seconds, and the server can\'t be reached: it, or your connection, may be down.');
    });
  }
  // The connection failed, so the server never answered: the draft is
  // given back to retry.
  function hostDown(mine) {
    if (pending !== mine) return;
    settle();
    showAlert('The connection to the server failed before it answered, so your message may or may not have been stored. Your draft is kept: look for the message above before you send it again.');
  }

  // The server's words for a refusal: its plain text, or the words of the
  // page it answered with (a 403 is a page).
  function refusalWords(answer, code) {
    var said = answer.trim();
    if (said.charAt(0) === '<') {
      var parsed = document.createElement('template');
      parsed.innerHTML = said;
      var p = parsed.content.querySelector('p');
      said = p ? p.textContent.trim() : '';
    }
    return said || 'Not sent (the server answered ' + code + ').';
  }

  // The status line's notice that a message this page sent has arrived, a
  // link that brings it into view and selects it. It names where the
  // message went, the page's place, then the message's reference: "your
  // message was sent to Apoorva as MSG_rant_8".
  function sentNotice(article) {
    var ref = article.querySelector('header a');
    var link = document.createElement('a');
    link.href = '#' + article.id;
    var reference = ref ? ref.textContent : article.id;
    link.textContent = '✓ your message was sent to ' + place + ' as ' + reference;
    // script-calls: runtime-only: a click on the sent notice, once feed.js has run
    link.addEventListener('click', function (e) {
      e.preventDefault();
      Feed.reveal(article);
    });
    status.textContent = '';
    status.style.color = 'var(--cc-notify-fg)';
    status.appendChild(link);
    sentLink = link;
  }
  // The placeholder names where a message goes, as the sent notice does:
  // "Message Apoorva" in a DM, "Message #general › roc-chat" in a channel's
  // topic.
  box.placeholder = 'Message ' + place + (place.charAt(0) === '#' ? ' › ' + topic : '');

  function expectArrival(id) {
    var here = document.getElementById(id);
    if (here) sentNotice(here);
    else awaitingArrival[id] = true;
  }

  // The id of the message a 201 answers with: its element's.
  function sentId(answer) {
    var parsed = document.createElement('template');
    parsed.innerHTML = answer;
    var article = parsed.content.querySelector('article');
    return article ? article.id : '';
  }

  function sendMessage() {
    if (pending || uploading) return;
    var markdown = box.value;
    if (!markdown.trim()) return;
    var mine = { timer: null, checkTimer: null, started: Date.now() };
    pending = mine;
    refreshControls();
    status.style.color = '';
    status.textContent = 'Sending…';
    mine.timer = setTimeout(function () { stillSending(mine); }, STILL_SENDING_MS);
    mine.checkTimer = setTimeout(function () { checkServer(mine); }, NO_ANSWER_MS);
    fetch(sendUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: box.name + '=' + encodeURIComponent(markdown),
    }).then(function (r) {
      if (pending !== mine) return;
      if (r.ok) {
        // Stored: the box empties now, even if the answer's body is lost on
        // the way, so a lost body never gives back a draft to send twice.
        box.value = '';
        settle();
        box.focus();
        r.text().then(function (answer) {
          var id = sentId(answer);
          if (id) expectArrival(id);
        }, function () {});
        return;
      }
      return r.text().then(function (answer) {
        settle();
        status.style.color = ERROR;
        status.textContent = refusalWords(answer, r.status);
        box.focus();
      }, function () {
        settle();
        status.style.color = ERROR;
        status.textContent = refusalWords('', r.status);
        box.focus();
      });
    }, function () { hostDown(mine); });
  }

  // Whether a send or an upload is on its way, saying so in the status line
  // when one is: the box is not to change under it.
  function refusedWhileBusy(doing) {
    if (!pending && !uploading) return false;
    status.style.color = '';
    status.textContent = 'Wait for your ' + (pending ? 'send' : 'upload') + ' to finish, then ' + doing + '.';
    return true;
  }

  // feed.js hands each message the stream brings to Compose.arrived.
  // actions.js loads an edit into the box with Compose.load: the box opened,
  // its text replaced, and the caret at `caret`, as chat-client's edit did.
  // It puts a quote-reply at the caret with Compose.insert, the box opened
  // and the caret after the text, so a quote joins a draft and never
  // replaces it. Neither touches the box while a send or an upload is on its
  // way (a send's answer would empty it; an upload's image would land in
  // it), and an edit never replaces a draft: each opens the box and says
  // why in the status line instead. (Refusing is lighter than asking to
  // replace: send or clear the draft, then press e again.) It says a
  // citation was copied with Compose.notice, the status line's words, which
  // answers whether they were shown: only while the box is open and no send
  // is on its way.
  window.Compose = {
    isOpen: function () { return compose.classList.contains('open'); },
    notice: function (words, failed) {
      if (pending || !compose.classList.contains('open')) return false;
      status.style.color = failed ? ERROR : 'var(--cc-notify-fg)';
      status.textContent = words;
      return true;
    },
    arrived: function (article) {
      if (!awaitingArrival[article.id]) return;
      delete awaitingArrival[article.id];
      sentNotice(article);
    },
    load: function (text, caret) {
      openCompose();
      if (refusedWhileBusy('edit a message')) return;
      if (box.value.trim() !== '' && box.value !== text) {
        status.style.color = '';
        status.textContent = 'You have a draft: send it or clear it first, then edit.';
        return;
      }
      box.value = text;
      box.setSelectionRange(caret, caret);
      refreshControls();
    },
    insert: function (text) {
      openCompose();
      if (refusedWhileBusy('quote')) return;
      insertAtCursor(text);
    },
  };

  box.addEventListener('input', function () {
    refreshControls();
    if (sentLink && sentLink.parentNode === status) {
      sentLink = null;
      status.textContent = '';
      status.style.color = '';
    }
  });
  form.addEventListener('submit', function (e) {
    e.preventDefault();
    sendMessage();
  });
  box.addEventListener('keydown', function (e) {
    if (e.isComposing) return;
    // Escape closes an empty box and leaves one holding text, as chat-client's
    // did; emoji.js's menu, open only over text, takes its own Escape.
    if (e.key === 'Escape' && box.value.trim() === '') {
      e.preventDefault();
      closeCompose();
      return;
    }
    if (e.key !== 'Enter' || !(e.ctrlKey || e.metaKey)) return;
    e.preventDefault();
    sendMessage();
  });

  var uploadUrl = form.getAttribute('data-upload');
  var imageByteLimit = Number(form.getAttribute('data-image-byte-limit'));
  if (!uploadUrl || !(imageByteLimit > 0)) {
    throw new Error('compose.js: the form has no data-upload, or a data-image-byte-limit that is no count');
  }
  var UPLOAD_PATIENCE_MS = 5 * 60 * 1000;
  var PHOTO_LONGEST_PX = 2048;
  var PHOTO_REENCODE_OVER_BYTES = 1.5 * 1048576;
  var PHOTO_JPEG_QUALITY = 0.85;
  var PHOTO_PREPARE_MS = 15000;
  var JPEG_TYPES = { 'image/jpeg': 1, 'image/jpg': 1, 'image/pjpeg': 1 };
  var uploading = false;

  function megabytes(n) { return (n / 1048576).toFixed(1) + ' MB'; }

  function insertAtCursor(text) {
    var start = box.selectionStart, end = box.selectionEnd, value = box.value;
    box.value = value.slice(0, start) + text + value.slice(end);
    box.selectionStart = box.selectionEnd = start + text.length;
    refreshControls();
    box.focus();
  }

  // The resize a picture gets: null to send it as it is, else the size and
  // type to draw it at.
  function resizePlan(type, bytes, width, height) {
    var jpeg = JPEG_TYPES[type] === 1;
    if (!(jpeg || type === 'image/png') || !(width > 0 && height > 0)) return null;
    var longest = Math.max(width, height);
    var scale = longest > PHOTO_LONGEST_PX ? PHOTO_LONGEST_PX / longest : 1;
    if (scale === 1 && !(jpeg && bytes > PHOTO_REENCODE_OVER_BYTES)) return null;
    return {
      width: Math.max(1, Math.round(width * scale)),
      height: Math.max(1, Math.round(height * scale)),
      type: jpeg ? 'image/jpeg' : 'image/png',
    };
  }

  // Hands `then` the file to send, exactly once: the shrunk one, or the
  // original. The decode is an <img>'s, which every current browser turns
  // upright by the photo's EXIF orientation.
  function shrinkPicture(file, then) {
    var handed = false, url = null;
    function hand(f) {
      if (handed) return;
      handed = true;
      clearTimeout(watchdog);
      if (url) URL.revokeObjectURL(url);
      then(f);
    }
    var watchdog = setTimeout(function () { hand(file); }, PHOTO_PREPARE_MS);
    if (!(JPEG_TYPES[file.type] === 1 || file.type === 'image/png')) return hand(file);
    try {
      url = URL.createObjectURL(file);
      var img = new Image();
      img.onerror = function () { hand(file); };
      img.onload = function () {
        try {
          var plan = resizePlan(file.type, file.size, img.naturalWidth, img.naturalHeight);
          if (!plan) return hand(file);
          var canvas = document.createElement('canvas');
          canvas.width = plan.width;
          canvas.height = plan.height;
          var g = canvas.getContext('2d');
          if (!g) return hand(file);
          if (plan.type === 'image/jpeg') { g.fillStyle = '#fff'; g.fillRect(0, 0, plan.width, plan.height); }
          g.imageSmoothingQuality = 'high';
          g.drawImage(img, 0, 0, plan.width, plan.height);
          canvas.toBlob(function (blob) {
            try {
              canvas.width = canvas.height = 0;
              if (!blob || blob.size >= file.size) return hand(file);
              var name = (file.name || 'image').replace(/\.[^.]*$/, '') + (plan.type === 'image/jpeg' ? '.jpg' : '.png');
              hand(new File([blob], name, { type: plan.type }));
            } catch (err) { hand(file); }
          }, plan.type, PHOTO_JPEG_QUALITY);
        } catch (err) { hand(file); }
      };
      img.src = url;
    } catch (err) { hand(file); }
  }

  // An upload's end: `line` is empty when it worked, else what went wrong.
  function uploadDone(line) {
    uploading = false;
    refreshControls();
    status.style.color = line ? ERROR : '';
    status.textContent = line;
  }

  function sendFile(file) {
    if (file.size > imageByteLimit) {
      return uploadDone('That image is ' + megabytes(file.size) + ' — too big to send (limit ' + (imageByteLimit / 1048576) + ' MB). Try compressing or resizing it.');
    }
    status.style.color = '';
    status.textContent = 'Uploading image: 0% of ' + megabytes(file.size) + '…';
    var formData = new FormData();
    formData.append('file', file);
    var xhr = new XMLHttpRequest();
    xhr.open('POST', uploadUrl);
    xhr.timeout = UPLOAD_PATIENCE_MS;
    xhr.upload.onprogress = function (e) {
      if (!e.lengthComputable) return;
      var percent = Math.floor(100 * e.loaded / e.total);
      status.textContent = percent < 100 ? 'Uploading image: ' + percent + '% of ' + megabytes(e.total) + '…' : 'Saving image…';
    };
    xhr.onload = function () {
      if (xhr.status < 200 || xhr.status >= 300) {
        var said = (xhr.responseText || '').trim();
        return uploadDone((said && said.charAt(0) !== '<' && said.length < 200) ? said : 'Upload failed.');
      }
      var answer;
      try { answer = JSON.parse(xhr.responseText); } catch (err) { return uploadDone('Upload failed: the answer did not read (' + err.message + ').'); }
      var alt = (answer.name || 'image').replace(/["<>\r\n]/g, '');
      var size = (answer.width > 0 && answer.height > 0) ? ' width="' + answer.width + '" height="' + answer.height + '"' : '';
      insertAtCursor('<img src="' + answer.url + '" alt="' + alt + '"' + size + '>');
      uploadDone('');
    };
    xhr.onerror = function () { uploadDone('Upload failed: the connection dropped. Please try again.'); };
    xhr.ontimeout = function () { uploadDone('Upload gave up after ' + (UPLOAD_PATIENCE_MS / 60000) + ' minutes. Please try again.'); };
    xhr.send(formData);
  }

  function uploadFile(file) {
    if (!file) return;
    if (pending) {
      status.style.color = '';
      status.textContent = 'Wait for your send to finish, then add the image.';
      return;
    }
    if (uploading) {
      status.style.color = '';
      status.textContent = 'Still sending the last upload — one at a time, please.';
      return;
    }
    uploading = true;
    refreshControls();
    status.style.color = '';
    status.textContent = 'Preparing image…';
    shrinkPicture(file, sendFile);
  }

  refreshControls();
  uploadButton.addEventListener('click', function () { picker.click(); });
  picker.addEventListener('change', function () { uploadFile(picker.files[0]); picker.value = ''; });
  // Drops: a count of the drag's enters and leaves over the box's parts,
  // so moving between them keeps the outline.
  var dragDepth = 0;
  function carriesFiles(e) {
    return !!e.dataTransfer && Array.prototype.indexOf.call(e.dataTransfer.types || [], 'Files') >= 0;
  }
  function endDrag() {
    dragDepth = 0;
    compose.classList.remove('compose-drop-over');
  }
  composeBody.addEventListener('dragenter', function (e) {
    if (!carriesFiles(e)) return;
    e.preventDefault();
    dragDepth++;
    compose.classList.add('compose-drop-over');
  });
  composeBody.addEventListener('dragover', function (e) {
    if (!carriesFiles(e)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = 'copy';
  });
  composeBody.addEventListener('dragleave', function (e) {
    if (!carriesFiles(e)) return;
    dragDepth = Math.max(0, dragDepth - 1);
    if (dragDepth === 0) compose.classList.remove('compose-drop-over');
  });
  composeBody.addEventListener('drop', function (e) {
    if (!carriesFiles(e)) return;
    e.preventDefault();
    endDrag();
    var files = e.dataTransfer.files;
    for (var i = 0; i < files.length; i++) {
      if (files[i].type.indexOf('image/') === 0) { uploadFile(files[i]); return; }
    }
    status.style.color = ERROR;
    status.textContent = 'Only an image can be dropped here: PNG, JPEG, GIF or WebP.';
  });
  window.addEventListener('dragend', endDrag);
  box.addEventListener('paste', function (e) {
    var files = e.clipboardData && e.clipboardData.files;
    if (files) {
      for (var i = 0; i < files.length; i++) {
        if (files[i].type.indexOf('image/') === 0) { e.preventDefault(); uploadFile(files[i]); return; }
      }
    }
  });
})();
