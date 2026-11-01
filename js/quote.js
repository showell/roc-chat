/* quote.js: quote-reply and edit, q and e, the old client's (chat-client's
   js/chat.js `doQuote`, `doEdit`; js/message.js `buildMeta`, its click
   routing and `markEdited`'s look). The server draws each bubble's
   "quote-reply" and "edit" (app/Bubble.roc) and writes the text: the
   reference, the "I said" or "you said", the fence one tilde longer than
   any inside, the "Edit of" line and where the cursor goes
   (app/Edits.roc, through the page's `quote` and `edit` routes). This
   script asks for it and puts it in the compose box:
     - q (r and > too), or a bubble's "quote-reply": the selected message
       quoted at the cursor, compose opened;
     - e, or a bubble's "edit": one's own message, under "Edit of", in
       place of the box's text, the cursor at its first line;
     - neither while a send is out; with nothing selected, or another's
       message for e, the key does nothing (the browser keeps it);
     - the ask has compose's host-down rule: no answer in 3 s is the same
       modal ("The host may be down. Please retry."), and an answer after
       that is dropped; a refusal or a lost answer is said in the compose
       status, never over a send's "Sending…";
     - an edited message's "Edited in" link selects the edit, when it is on
       the page, as the old `msg-ref` click did (the old navigateRef; a ref
       to a message not loaded is the later N7's).
   The style is the server markup's, one <style>, as the old widget's: the
   meta line's buttons, and an edited message's note and spoiler. */
(function () {
  'use strict';
  var root = document.body;
  var bubbles = document.getElementById('chat-bubbles');

  var s = document.createElement('style');
  s.textContent = ''
    + '.chat-meta .msg-quote, .chat-meta .msg-edit {'
    + ' font-size:10px; color:var(--cc-muted-fg); background:none; border:none;'
    + ' padding:0 2px; cursor:pointer; text-decoration:underline; }'
    + '.chat-meta .msg-quote:hover, .chat-meta .msg-edit:hover { color:var(--cc-accent); }'
    + '.chat-edited-note { font-size:12px; color:var(--cc-muted-fg); margin-bottom:4px; }'
    + '.chat-edited-spoiler > summary { font-size:11px; color:var(--cc-muted-fg); cursor:pointer; list-style:none; }'
    + '.chat-edited-spoiler > summary::-webkit-details-marker { display:none; }'
    + '.chat-edited-spoiler > summary::before { content:"▸ "; }'
    + '.chat-edited-spoiler[open] > summary::before { content:"▾ "; }'
    + '.chat-edited-orig { font-size:11px; color:var(--cc-soft-muted-fg); white-space:pre-wrap; overflow-wrap:anywhere;'
    + ' border-left:3px solid var(--cc-border); padding:2px 0 2px 8px; margin-top:4px; }';
  document.head.appendChild(s);

  /* The server's text for the bubble, then `put` with it, once: the
     answer, a refusal or a lost answer said in the compose box, or the
     host-down modal at 3 s, whichever comes first; the rest dropped. */
  function ask(url, bubble, put) {
    Feed.reveal(bubble);
    var settled = false;
    function first() {
      if (settled) return false;
      settled = true;
      clearTimeout(timer);
      return true;
    }
    var timer = setTimeout(function () {
      if (first()) Compose.alert('The host may be down. Please retry.');
    }, Compose.hostDownMs);
    fetch(url + '?n=' + bubble.dataset.id).then(function (r) {
      if (r.ok) return r.json();
      return r.text().then(function (why) { throw new Error(why.trim() || String(r.status)); });
    }).then(function (answer) {
      if (!first() || Compose.isPending()) return;
      Compose.open();
      put(answer);
    }, function (e) {
      if (!first() || Compose.isPending()) return;
      Compose.open();
      Compose.say('Could not load that message: ' + e.message);
    });
  }

  function quote(bubble) {
    if (!bubble || Compose.isPending()) return false;
    ask(root.dataset.quote, bubble, function (a) { Compose.insertAtCursor(a.text); });
  }
  function edit(bubble) {
    if (!bubble || Compose.isPending() || !bubble.classList.contains('mine')) return false;
    ask(root.dataset.edit, bubble, function (a) { Compose.setMarkdown(a.text, a.caret); });
  }

  bubbles.addEventListener('click', function (e) {
    var t = e.target;
    if (!t.closest) return;
    var edited = t.closest('.chat-edited-note a.msg-ref');
    if (edited) {
      e.preventDefault();
      var to = document.getElementById(edited.getAttribute('href').slice(1));
      if (to) Feed.reveal(to);
    } else if (t.closest('.msg-quote')) quote(t.closest('.chat-msg'));
    else if (t.closest('.msg-edit')) edit(t.closest('.chat-msg'));
  });

  var quoteKey = function () { return quote(Feed.selected()); };
  Keys.register({ key: 'q', label: 'quote-reply to selected message (q, r, or >)', run: quoteKey });
  Keys.register({ key: 'r', label: 'quote-reply', hidden: true, run: quoteKey });
  Keys.register({ key: '>', label: 'quote-reply', hidden: true, run: quoteKey });
  Keys.register({ key: 'e', label: 'edit selected message', run: function () { return edit(Feed.selected()); } });
})();
