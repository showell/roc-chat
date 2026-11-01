/* save.js: s, save to the reading list, the old client's (chat-client's
   js/chat.js `doSave`, `postSave`, `savedStatus`; js/chat_save_popup.js;
   js/message.js `applySaved`). The server draws each bubble's "save", and
   "✓ saved" on the viewer's own page for each message on their list
   (app/Bubble.roc), keeps the list (app/ReadingList.roc), and draws the
   strip's line. This script:
     - s, or a bubble's "save": the old popup, a one-line note pre-filled
       "read later" (Enter saves; Esc, Cancel or the backdrop dismisses), the
       selection left as it is (the old doSave only opened the popup); with
       nothing selected the key does nothing (the browser keeps it);
     - the note POSTed (`n=`, `note=`) while the popup waits: a refusal is
       the server's own words in the popup, which stays for another try; no
       answer at all, "Save failed" there;
     - a confirmed save, never an optimistic one, closes the popup, flips the
       bubble to "✓ saved" and puts the server's line in the strip ("MSG_…
       saved to reading list", the list linked).
   The popup styles its own elements (Object.assign); the <style> holds what
   cannot be inlined: the backdrop, and the server markup's button. */
(function () {
  'use strict';
  var root = document.body;
  var bubbles = document.getElementById('chat-bubbles');
  var notify = document.getElementById('chat-notify');

  var s = document.createElement('style');
  s.textContent = ''
    + 'dialog.chat-save-dialog::backdrop { background:var(--cc-backdrop); }'
    + '.chat-meta .msg-save { font-size:10px; color:var(--cc-muted-fg); background:none; border:none;'
    + ' padding:0 2px; cursor:pointer; text-decoration:underline; }'
    + '.chat-meta .msg-save:hover { color:var(--cc-accent); }'
    + '.chat-meta .msg-save.saved { color:var(--cc-saved-fg); text-decoration:none; }';
  document.head.appendChild(s);

  /* A confirmed save: the bubble's link as the server draws it saved. */
  function markSaved(bubble) {
    var button = bubble.querySelector('.msg-save');
    if (!button) return;
    button.textContent = '✓ saved';
    button.classList.add('saved');
  }

  /* The old ChatSavePopup: a fresh <dialog> each time, removed on close,
     the focus going back where it was (the dialog's own). A commit calls
     `send(note, said)`; `said(line)` shows a refusal in the popup, and the
     popup is closed by the caller once the save is confirmed. */
  function popup(send) {
    var dlg = document.createElement('dialog');
    dlg.className = 'chat-save-dialog';
    Object.assign(dlg.style, {
      maxWidth: '90vw', width: '360px', padding: '0', border: '1px solid var(--cc-dialog-border)',
      borderRadius: '8px', background: 'var(--cc-bg)', color: 'var(--cc-fg)',
    });
    var form = document.createElement('form');
    form.method = 'dialog';
    Object.assign(form.style, { margin: '0', padding: '14px 16px' });
    var title = document.createElement('div');
    title.textContent = 'Save to reading list';
    Object.assign(title.style, { fontSize: '13px', color: 'var(--cc-muted-fg)', marginBottom: '8px' });
    var input = document.createElement('input');
    input.type = 'text';
    input.value = 'read later';
    Object.assign(input.style, {
      width: '100%', boxSizing: 'border-box', padding: '7px 9px', fontSize: '14px', color: 'var(--cc-fg)',
      background: 'var(--cc-bg)', border: '1px solid var(--cc-input-border)', borderRadius: '5px',
    });
    var hint = document.createElement('div');
    hint.textContent = 'Enter to save · Esc to cancel';
    Object.assign(hint.style, { fontSize: '11px', color: 'var(--cc-soft-muted-fg)', margin: '6px 2px 12px' });
    var row = document.createElement('div');
    Object.assign(row.style, { display: 'flex', justifyContent: 'flex-end', gap: '8px' });
    var cancel = document.createElement('button');
    cancel.type = 'button';
    cancel.textContent = 'Cancel';
    Object.assign(cancel.style, {
      padding: '6px 12px', fontSize: '13px', cursor: 'pointer', color: 'var(--cc-muted-fg)',
      background: 'none', border: '1px solid var(--cc-border)', borderRadius: '5px',
    });
    cancel.addEventListener('click', function () { dlg.close(); });
    var ok = document.createElement('button');
    ok.type = 'submit';
    ok.textContent = 'Save';
    Object.assign(ok.style, {
      padding: '6px 14px', fontSize: '13px', cursor: 'pointer', fontWeight: '600', color: '#fff',
      background: 'var(--cc-accent)', border: '1px solid var(--cc-accent)', borderRadius: '5px',
    });
    row.appendChild(cancel);
    row.appendChild(ok);
    form.appendChild(title);
    form.appendChild(input);
    form.appendChild(hint);
    form.appendChild(row);
    /* Enter or Save sends, and the popup waits for the answer; Cancel, Esc
       and the backdrop close it. */
    var sending = false;
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      if (sending) return;
      sending = true;
      ok.disabled = true;
      send(input.value, function (line) {
        sending = false;
        ok.disabled = false;
        hint.textContent = line;
        hint.style.color = 'var(--cc-error, #b00020)';
      });
    });
    dlg.addEventListener('close', function () { dlg.remove(); });
    dlg.addEventListener('click', function (e) { if (e.target === dlg) dlg.close(); });
    dlg.appendChild(form);
    document.body.appendChild(dlg);
    dlg.showModal();
    input.focus();
    input.select();
    return dlg;
  }

  /* The server's line for the strip, as its elements. */
  function strip(html) {
    var t = document.createElement('template');
    t.innerHTML = html;
    notify.textContent = '';
    notify.appendChild(t.content);
  }

  /* The note sent; the popup closed and the bubble flipped once the save is
     confirmed, else the refusal's words (or "Save failed") said in it. */
  function post(bubble, note, dlg, said) {
    var form = new URLSearchParams();
    form.set('n', bubble.dataset.id);
    form.set('note', note);
    fetch(root.dataset.save, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
    }).then(function (r) {
      return r.text().then(function (text) { return { ok: r.status === 201, text: text }; });
    }).then(function (answer) {
      if (!answer.ok) { said(answer.text.trim() || 'Save failed'); return; }
      if (dlg.open) dlg.close();
      markSaved(bubble);
      strip(answer.text);
    }, function () { said('Save failed'); });
  }

  function save(bubble) {
    if (!bubble) return false;
    var dlg = popup(function (note, said) { post(bubble, note, dlg, said); });
  }

  bubbles.addEventListener('click', function (e) {
    var t = e.target;
    if (t.closest && t.closest('.msg-save')) save(t.closest('.chat-msg'));
  });
  Keys.register({ key: 's', label: 'save selected message to your reading list', run: function () { return save(Feed.selected()); } });
})();
