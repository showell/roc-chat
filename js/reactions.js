/* reactions.js: reactions, : and +, the old client's (chat-client's
   js/chat_reactions.js `toggle`; js/chat.js `doPickReaction`, `thumbsUp`).
   The server keeps the events, folds them and draws each bubble's chips
   (app/Reactions.roc); a change comes to every page as a `reaction` event,
   which feed.js puts in place. This script:
     - a chip's click toggles that emoji on its message: on when the viewer
       is not on it, off when they are (the chip's data-by);
     - + toggles 👍 on the selected message;
     - : opens the picker (emoji.js, `Emoji.pick`) over the selected message,
       the transcript given the keyboard back when it closes;
     - a toggle POSTs the state wanted and waits for the event, never
       painting it itself (the old "never optimistic"); a refusal or no
       answer says "Reaction failed" in the strip.
   With nothing selected, : and + do nothing (the browser keeps the key). */
(function () {
  'use strict';
  var root = document.body;
  var me = root.dataset.me;
  var bubbles = document.getElementById('chat-bubbles');
  var notify = document.getElementById('chat-notify');
  var thumbsUp = Emoji.glyphOf('thumbsup');

  /* Whether the viewer is on `emoji` on `bubble`, by the server's chip. */
  function isMine(bubble, emoji) {
    var chips = bubble.querySelectorAll('.chat-react-chip');
    for (var i = 0; i < chips.length; i++) {
      if (chips[i].dataset.emoji === emoji) return (chips[i].dataset.by || '').split(' ').indexOf(me) >= 0;
    }
    return false;
  }

  /* The old toggle: the state wanted POSTed; the event repaints. */
  function toggle(bubble, emoji) {
    var form = new URLSearchParams();
    form.set('msg', bubble.dataset.id);
    form.set('emoji', emoji);
    form.set('on', isMine(bubble, emoji) ? '0' : '1');
    fetch(root.dataset.react, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
    }).then(function (r) {
      if (r.status !== 204) notify.textContent = 'Reaction failed';
    }, function () { notify.textContent = 'Reaction failed'; });
  }

  bubbles.addEventListener('click', function (e) {
    var chip = e.target.closest && e.target.closest('.chat-react-chip');
    if (chip) toggle(chip.closest('.chat-msg'), chip.dataset.emoji);
  });
  Keys.register({
    key: ':', label: 'react to selected message (pick an emoji)',
    run: function () {
      var bubble = Feed.selected();
      if (!bubble) return false;
      Feed.reveal(bubble);
      Emoji.pick({ anchor: bubble, onPick: function (entry) { toggle(bubble, entry.glyph); }, onClose: Feed.focus });
    },
  });
  Keys.register({
    key: '+', label: 'thumbs-up the selected message',
    run: function () {
      var bubble = Feed.selected();
      if (!bubble) return false;
      toggle(bubble, thumbsUp);
    },
  });
})();
