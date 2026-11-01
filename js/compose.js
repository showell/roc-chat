/* compose.js: a topic page's compose box, the glue around what the server
   drew (app/TopicPage.roc, `compose_html`). The old client's, rebuilt
   (chat-client's js/chat_right_sidebar.js, js/chat_compose.js, and
   js/chat.js for the "sent" notice):
     - the right pane starts closed, its "Open compose box" button showing;
       the button and `c` open it and put the cursor in it; Esc in an empty
       box closes it and gives the transcript the keyboard ("never lose a
       draft": Esc in a box with text does nothing);
     - Send, or Ctrl/⌘-Enter, sends; Enter is a newline; a blank box sends
       nothing;
     - while a send is out, the box and its buttons are off and the status
       says "Sending…" in the muted colour;
     - the server's answer is the new message's bubble: the box empties,
       comes back on and keeps the cursor, the bubble goes in (Feed.place),
       and the strip says "✓ your message was sent to <ref>", a link to it;
     - no answer in 3 s, or no answer at all: "The host may be down. Please
       retry your send.", the text kept; an answer that comes after that
       still says "sent" (so it is not sent twice), and leaves the box be;
     - a refusal (the post's 4xx) says the server's own words, the text kept;
       a 5xx is a failure, as a lost answer is: the host-down modal;
     - hands quote.js `Compose` (the old ChatCompose's): open the box,
       whether a send is out, put text in at the cursor, set the whole text
       with the cursor at a place, and say a line in the status.
   The style is its own (the server sends none): one <style> for the markup
   the server drew, as the old widget's. */
(function () {
  'use strict';
  var hostDownMs = 3000;
  var body = document.getElementById('chat-compose-body');
  var closed = document.getElementById('chat-closed-panel');
  var form = document.getElementById('chat-form');
  var text = document.getElementById('chat-body');
  var status = document.getElementById('chat-status');
  var notify = document.getElementById('chat-notify');
  var openButton = document.getElementById('chat-open-compose');

  var s = document.createElement('style');
  s.textContent = ''
    + '.chat-compose-body { display:flex; flex-direction:column; flex:1; min-height:0; }'
    + '.chat-compose-body[hidden] { display:none; }'
    + '.chat-compose form { margin:0; display:flex; flex-direction:column; flex:1; min-height:0; }'
    + '.chat-compose textarea { width:100%; flex:1; min-height:0; resize:vertical; box-sizing:border-box;'
    + ' font-family:inherit; font-size:14px; padding:8px; background:var(--cc-card-bg); color:var(--cc-fg); border:1px solid var(--cc-input-border); }'
    + '.chat-compose-actions { display:flex; gap:8px; margin-top:8px; }'
    + '.chat-status { font-size:12px; color:var(--cc-error, #b00020); min-height:16px; margin-top:6px; }'
    + '.chat-hint { font-size:12px; color:var(--cc-soft-muted-fg, #999); margin-top:8px; }'
    + '.chat-open-compose { font-size:13px; padding:4px 12px; background:var(--cc-mine-bg); color:var(--cc-search-tok-fg); border:1px solid var(--cc-quote-border); border-radius:6px; cursor:pointer; }'
    + '.chat-open-compose:hover { background:var(--cc-accent-soft-hov); }'
    + '.chat-alert-dialog { background:var(--cc-bg); color:var(--cc-fg); }'
    + '.chat-alert-dialog { max-width:90vw; border:1px solid var(--cc-dialog-border, #888); border-radius:8px; padding:18px 20px; }'
    + '.chat-alert-dialog::backdrop { background:var(--cc-backdrop, rgba(0,0,0,0.3)); }'
    + '.chat-alert-dialog p { margin:0 0 14px; }'
    + '.chat-alert-dialog button { padding:5px 16px; }';
  document.head.appendChild(s);

  function open() {
    closed.hidden = true;
    body.hidden = false;
    text.focus();
  }
  function close() {
    body.hidden = true;
    closed.hidden = false;
    Feed.focus();
  }
  openButton.addEventListener('click', open);
  Keys.register({ key: 'c', label: 'compose', run: open });

  /* The one send out, if any: its timer, and whether it was given up on. */
  var pending = null;

  function setEnabled(on) {
    text.disabled = !on;
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

  /* The old alert: a modal, its OK, the cursor back in the box after. */
  function showAlert(message) {
    var dlg = document.createElement('dialog');
    dlg.className = 'chat-alert-dialog';
    var p = document.createElement('p');
    p.textContent = message;
    var ok = document.createElement('button');
    ok.type = 'button';
    ok.textContent = 'OK';
    ok.addEventListener('click', function () { dlg.close(); });
    dlg.appendChild(p);
    dlg.appendChild(ok);
    dlg.addEventListener('close', function () { dlg.remove(); text.focus(); });
    document.body.appendChild(dlg);
    dlg.showModal();
  }
  function hostDown(send) {
    if (pending !== send) return;
    settle();
    send.gaveUp = true;
    showAlert('The host may be down. Please retry your send.');
  }

  /* The strip: "✓ your message was sent to <ref>", a link that brings the
     bubble into view and gives it the keyboard. */
  function sentNotice(bubble) {
    var link = document.createElement('a');
    link.href = '#' + bubble.id;
    link.textContent = '✓ your message was sent to ' + bubble.dataset.ref;
    link.addEventListener('click', function (e) {
      e.preventDefault();
      Feed.reveal(bubble);
    });
    notify.textContent = '';
    notify.appendChild(link);
  }

  function send() {
    if (pending) return;
    var markdown = text.value;
    if (!markdown.trim()) return;
    var mine = { timer: null, gaveUp: false };
    pending = mine;
    setEnabled(false);
    status.style.color = 'var(--cc-muted-fg, #888)';
    status.textContent = 'Sending…';
    mine.timer = setTimeout(function () { hostDown(mine); }, hostDownMs);
    fetch(form.dataset.send, { method: 'POST', body: markdown }).then(function (r) {
      return r.text().then(function (answer) {
        if (r.status === 201) {
          var bubble = Feed.place(answer);
          if (pending === mine) {
            settle();
            text.value = '';
            text.focus();
          }
          if (bubble) sentNotice(bubble);
        } else if (r.status >= 500) {
          hostDown(mine);
        } else if (pending === mine) {
          settle();
          status.textContent = answer.trim() || ('not sent (' + r.status + ')');
        }
      });
    }).catch(function () { hostDown(mine); });
  }

  /* The old insertAtCursor: the text in place of the selection, the
     cursor after it. */
  function insertAtCursor(more) {
    var from = text.selectionStart, to = text.selectionEnd, v = text.value;
    text.value = v.slice(0, from) + more + v.slice(to);
    text.selectionStart = text.selectionEnd = from + more.length;
    text.focus();
  }
  /* The old setMarkdown: the whole text, the cursor at `caret`. */
  function setMarkdown(whole, caret) {
    text.value = whole;
    text.focus();
    if (typeof caret === 'number') text.setSelectionRange(caret, caret);
  }
  window.Compose = {
    open: open,
    isPending: function () { return pending !== null; },
    insertAtCursor: insertAtCursor,
    setMarkdown: setMarkdown,
    say: function (line) { status.textContent = line; },
  };

  form.addEventListener('submit', function (e) { e.preventDefault(); send(); });
  text.addEventListener('keydown', function (e) {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') { e.preventDefault(); send(); return; }
    if (e.key === 'Escape' && text.value.trim() === '') { e.preventDefault(); close(); }
  });
})();
