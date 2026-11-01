/* save.js: s, save to the reading list, the old client's (chat-client's
   js/chat.js `doSave`, `postSave`, `savedStatus` and the saved set;
   js/chat_save_popup.js; js/message.js `applySaved`). The server draws each
   bubble's "save" (app/Bubble.roc), keeps the list (app/ReadingList.roc)
   and names, on the page, which of this topic's messages the viewer saved
   (`data-saved`: one bubble goes to every viewer, and "✓ saved" is the
   viewer's alone). This script:
     - marks those bubbles "✓ saved" in green, and each that comes after
       (live, or an earlier page);
     - s, or a bubble's "save": the old popup, a one-line note pre-filled
       "read later" (Enter saves; Esc, Cancel or the backdrop dismisses),
       then the save POSTed (`n=`, `note=`); with nothing selected the key
       does nothing (the browser keeps it);
     - a confirmed save, never an optimistic one, marks the bubble and
       says "<ref> saved to your reading list" in the strip, the list
       linked; anything else says "Save failed".
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

  /* The numbers saved here: the page's, then each confirmed save. */
  var saved = Object.create(null);
  (root.dataset.saved || '').split(' ').forEach(function (n) { if (n) saved[n] = true; });

  function mark(bubble) {
    var button = bubble.querySelector('.msg-save');
    if (!button) return;
    var is = !!saved[bubble.dataset.id];
    button.textContent = is ? '✓ saved' : 'save';
    button.classList.toggle('saved', is);
  }
  Array.prototype.forEach.call(bubbles.querySelectorAll('.chat-msg'), mark);
  /* A bubble put in later (the stream, an earlier page) is marked as it lands. */
  new MutationObserver(function (changes) {
    changes.forEach(function (c) {
      Array.prototype.forEach.call(c.addedNodes, function (n) {
        if (n.nodeType === 1 && n.classList.contains('chat-msg')) mark(n);
      });
    });
  }).observe(bubbles, { childList: true });

  /* The old ChatSavePopup: a fresh <dialog> each time, removed on close;
     `onConfirm` only when the note was committed. */
  function popup(onConfirm) {
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
    /* Enter, Save or a submit all commit; Cancel, Esc and the backdrop do not. */
    var committed = false;
    form.addEventListener('submit', function () { committed = true; });
    dlg.addEventListener('close', function () {
      var note = input.value;
      dlg.remove();
      Feed.focus();
      if (committed) onConfirm(note);
    });
    dlg.addEventListener('click', function (e) { if (e.target === dlg) dlg.close(); });
    dlg.appendChild(form);
    document.body.appendChild(dlg);
    dlg.showModal();
    input.focus();
    input.select();
  }

  /* The strip: "<ref> saved to your reading list", the list linked. */
  function say(ref, list) {
    var span = document.createElement('span');
    span.appendChild(document.createTextNode(ref + ' saved to '));
    var a = document.createElement('a');
    a.href = list;
    a.textContent = 'your reading list';
    span.appendChild(a);
    notify.textContent = '';
    notify.appendChild(span);
  }
  function failed() { notify.textContent = 'Save failed'; }

  function post(bubble, note) {
    var form = new URLSearchParams();
    form.set('n', bubble.dataset.id);
    form.set('note', note);
    fetch(root.dataset.save, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
    }).then(function (r) {
      return r.status === 201 ? r.json() : null;
    }).then(function (a) {
      if (a === null) { failed(); return; }
      saved[bubble.dataset.id] = true;
      mark(bubble);
      say(a.ref, a.list);
    }, failed);
  }

  function save(bubble) {
    if (!bubble) return false;
    Feed.reveal(bubble);
    popup(function (note) { post(bubble, note); });
  }

  bubbles.addEventListener('click', function (e) {
    var t = e.target;
    if (t.closest && t.closest('.msg-save')) save(t.closest('.chat-msg'));
  });
  Keys.register({ key: 's', label: 'save selected message to your reading list', run: function () { return save(Feed.selected()); } });
})();
