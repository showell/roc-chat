// This script runs on a conversation page, which app/Page.roc builds and
// app/ComposeScript.roc serves. The page works without it: the form posts,
// and the messages read top to bottom.
//
// The layout follows chat-client's. In a window wider than 768 pixels, the
// messages are on the left and the compose box is a rail 320 pixels wide on
// the right. The rail is either open, its textarea as tall as the window,
// or closed, showing an "Open compose box" button and the keyboard help. It
// starts closed, and opens with the button or the c key. Escape closes it
// when the textarea is empty, so a draft stays where it is. In a narrower
// window, the compose box is always open, below the messages.
//
// Ctrl+Enter (⌘+Enter on a Mac) sends, as chat-client does; plain Enter is
// a new line.
//
// A send stays on the page, as chat-client's did (js/chat_compose.js). The
// script posts the form to the conversation's `/send` (the form's
// data-send), and the box and its buttons are off until the server answers,
// the status line saying "Sending…". The server answers a 201 with the
// message's HTML once the message is stored; then the box empties and comes
// back on. The message itself appears through the stream, as everyone else
// sees it, and when it arrives there the status line says it was sent,
// linking to it. A refusal shows the server's own words and keeps the
// draft. With no answer in 3 seconds, a dialog says the host may be down,
// and the draft is kept; an answer that comes later still says "sent" when
// the message arrives, so it is not sent twice.
//
// An image goes into a message as chat-client's compose box puts one there.
// The Upload button picks a file, and an image pasted into the box is sent
// the same way. A large photo is first shrunk in the browser: its longest
// side to 2048 pixels, a JPEG over 1.5 MB re-encoded, a PNG scaled and kept
// a PNG, and a GIF or WebP sent as it is. The original is sent whenever the
// shrunk one is no smaller, or shrinking fails or takes over 15 seconds. One
// upload runs at a time, its progress shown, and it is given up after five
// minutes. The server keeps the image in the conversation and answers its
// URL, and the script puts an <img> of it at the cursor. The form names where
// to upload (data-upload) and the most an image may be (data-image-most).
//
// The messages pane, its stream and the newest message's place in view are
// feed.js's; this script runs before it, so the panes are laid out by the
// time feed.js first scrolls to the newest message, and Compose is there for
// feed.js to use.
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

  // The breakpoint, chat-client's: a window at most this wide is narrow.
  var narrowQuery = window.matchMedia('(max-width:768px)');

  // The colours are palette.js's, by chat-client's names, as roc-chat's
  // compose.js uses them.
  var styleSheet = document.createElement('style');
  styleSheet.textContent = [
    '.compose-actions{display:flex;gap:8px}',
    '.compose-status{font-size:12px;color:var(--cc-error);min-height:16px;margin-top:6px}',
    '.compose textarea{box-sizing:border-box;font-family:inherit;font-size:14px;padding:8px;' +
      'background:var(--cc-card-bg);color:var(--cc-fg);border:1px solid var(--cc-input-border)}',
    '.compose .help{font-size:12px;color:var(--cc-soft-muted-fg)}',

    // A narrow window: the messages, then the compose box below them.
    'html.layout-narrow .layout{flex-direction:column;gap:8px}',
    'html.layout-narrow .compose{flex:none}',
    'html.layout-narrow .compose-closed{display:none}',
    'html.layout-narrow .compose form{display:flex;gap:.5rem;align-items:flex-end}',
    'html.layout-narrow .compose textarea{flex:1 1 auto;resize:vertical}',
    'html.layout-narrow .compose .help{margin:.25rem 0 0}',

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
    '.open-compose{font-size:13px;padding:4px 12px;background:var(--cc-mine-bg);color:var(--cc-search-tok-fg);' +
      'border:1px solid var(--cc-quote-border);border-radius:6px;cursor:pointer}',
    '.open-compose:hover{background:var(--cc-accent-soft-hov)}',
    '.keyhelp{margin-top:18px;font-size:13px;color:var(--cc-body-muted-fg)}',
    '.keyhelp-title{font-weight:bold;color:var(--cc-meta-fg);margin-bottom:7px}',
    '.keyhelp-row{margin:5px 0}',
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
  var uploadButton = document.createElement('button');
  uploadButton.type = 'button';
  uploadButton.textContent = 'Upload';
  actions.appendChild(uploadButton);
  var picker = document.createElement('input');
  picker.type = 'file';
  picker.accept = 'image/png,image/jpeg,image/gif,image/webp';
  picker.hidden = true;
  var status = document.createElement('div');
  status.className = 'compose-status';
  compose.insertBefore(composeBody, form);
  composeBody.appendChild(form);
  composeBody.appendChild(picker);
  composeBody.appendChild(status);
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

  if (isNarrow()) {
    openCompose();
  } else {
    messages.focus();
  }

  var sendUrl = form.getAttribute('data-send');
  if (!sendUrl) throw new Error('compose.js: the form has no data-send');
  var MUTED = 'var(--cc-muted-fg)';
  var HOST_DOWN_MS = 3000;

  // The one send on its way, if any: its timer. A second send waits for it,
  // so one Ctrl+Enter pressed twice never posts the message twice.
  var pending = null;
  // The ids of the messages this page sent whose arrival on the stream is
  // still to be noticed.
  var awaitingArrival = Object.create(null);

  function setEnabled(on) {
    box.disabled = !on;
    var buttons = form.querySelectorAll('button');
    for (var i = 0; i < buttons.length; i++) buttons[i].disabled = !on;
  }
  function settle() {
    clearTimeout(pending.timer);
    pending = null;
    status.textContent = '';
    status.style.color = '';
    setEnabled(true);
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
  function hostDown(mine) {
    if (pending !== mine) return;
    settle();
    showAlert('The host may be down. Please retry your send.');
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
  // link that brings it into view.
  function sentNotice(article) {
    var ref = article.querySelector('header a');
    var link = document.createElement('a');
    link.href = '#' + article.id;
    link.textContent = '✓ your message was sent to ' + (ref ? ref.textContent : article.id);
    link.addEventListener('click', function (e) {
      e.preventDefault();
      Feed.reveal(article);
    });
    status.textContent = '';
    status.style.color = 'var(--cc-notify-fg)';
    status.appendChild(link);
  }
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
    if (pending) return;
    var markdown = box.value;
    if (!markdown.trim()) return;
    var mine = { timer: null };
    pending = mine;
    setEnabled(false);
    status.style.color = MUTED;
    status.textContent = 'Sending…';
    mine.timer = setTimeout(function () { hostDown(mine); }, HOST_DOWN_MS);
    fetch(sendUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: box.name + '=' + encodeURIComponent(markdown),
    }).then(function (r) {
      return r.text().then(function (answer) {
        if (r.status === 201) {
          if (pending === mine) {
            settle();
            box.value = '';
            box.focus();
          }
          var id = sentId(answer);
          if (id) expectArrival(id);
        } else if (pending === mine) {
          settle();
          status.textContent = refusalWords(answer, r.status);
          box.focus();
        }
      });
    }).catch(function () { hostDown(mine); });
  }

  // feed.js hands each message the stream brings to Compose.arrived.
  window.Compose = {
    arrived: function (article) {
      if (!awaitingArrival[article.id]) return;
      delete awaitingArrival[article.id];
      sentNotice(article);
    },
  };

  form.addEventListener('submit', function (e) {
    e.preventDefault();
    sendMessage();
  });
  box.addEventListener('keydown', function (e) {
    if (e.isComposing) return;
    if (e.key === 'Escape' && !isNarrow() && box.value.trim() === '') {
      e.preventDefault();
      closeCompose();
      return;
    }
    if (e.key !== 'Enter' || !(e.ctrlKey || e.metaKey)) return;
    e.preventDefault();
    sendMessage();
  });

  var uploadUrl = form.getAttribute('data-upload');
  var imageMost = Number(form.getAttribute('data-image-most'));
  if (!uploadUrl || !(imageMost > 0)) {
    throw new Error('compose.js: the form has no data-upload, or a data-image-most that is no count');
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

  function uploadDone(line) {
    uploading = false;
    uploadButton.disabled = false;
    status.style.color = '';
    status.textContent = line;
  }

  function sendFile(file) {
    if (file.size > imageMost) {
      return uploadDone('That image is ' + megabytes(file.size) + ' — too big to send (limit ' + (imageMost / 1048576) + ' MB). Try compressing or resizing it.');
    }
    status.style.color = MUTED;
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
    if (uploading) {
      status.style.color = '';
      status.textContent = 'Still sending the last upload — one at a time, please.';
      return;
    }
    uploading = true;
    uploadButton.disabled = true;
    status.style.color = MUTED;
    status.textContent = 'Preparing image…';
    shrinkPicture(file, sendFile);
  }

  uploadButton.addEventListener('click', function () { picker.click(); });
  picker.addEventListener('change', function () { uploadFile(picker.files[0]); picker.value = ''; });
  box.addEventListener('paste', function (e) {
    var files = e.clipboardData && e.clipboardData.files;
    if (files) {
      for (var i = 0; i < files.length; i++) {
        if (files[i].type.indexOf('image/') === 0) { e.preventDefault(); uploadFile(files[i]); return; }
      }
    }
  });
})();
