/* feed.js: a topic page's transcript, the glue around what the server drew.

   The page arrives rendered (app/TopicPage.roc): every bubble is the
   server's HTML (app/Bubble.roc), and so is every live one, sent whole on
   the page's stream. This script only:
     - marks each bubble mine or theirs, from the page's viewer (data-me)
       and the bubble's author (data-by), as Gopher Chat's client did
       (chat-client js/chat.js, `m.mine`), since one fragment goes to every
       viewer;
     - writes each time in the viewer's zone, "Jan 2 · 3:04 PM"
       (js/message.js, formatLocalTime), since the server does not know it;
     - puts a live bubble in place, once (by its id: the stream starts after
       the newest message drawn here, and a reconnect resumes after the last
       one it sent);
     - follows new messages only when the reader was caught up, read before
       the append (js/chat.js:308-316, js/middle_pane.js:88-93);
     - starts at the bottom, held there while images decode, until the
       reader scrolls or 5 s pass (js/message_view.js, `stabilize`);
     - puts a page of earlier bubbles, from the server, above the first;
     - hands compose.js `Feed`: place a bubble, reveal one, focus the feed;
     - styles the transcript's column and the right pane on their elements
       (js/middle_pane.js, js/chat_right_sidebar.js), the server sending no
       style. */
(function () {
  'use strict';

  var root = document.body;
  var me = root.dataset.me;
  var history = document.getElementById('chat-history');
  var bubbles = document.getElementById('chat-bubbles');
  var earlier = document.getElementById('earlier');
  var stabilizeMs = 5000;
  var scrollQuietMs = 150;

  /* The two panes, as the old client set them on its elements; only what
     cannot be inlined goes in a <style>. */
  Object.assign(document.querySelector('.chat-layout').style, {
    display: 'flex', flexDirection: 'row', alignItems: 'stretch', gap: '20px', flex: '1', minHeight: '0',
  });
  Object.assign(document.getElementById('chat-feed').style, {
    minWidth: '0', flex: '1', maxWidth: '600px', display: 'flex', flexDirection: 'column', minHeight: '0',
  });
  Object.assign(document.querySelector('.chat-mp-nav').style, { marginBottom: '8px' });
  Object.assign(history.style, {
    minWidth: '0', flex: '1', minHeight: '0', overflowY: 'auto',
    border: '1px solid var(--cc-border)', borderRadius: '8px', padding: '12px', background: 'var(--cc-card-bg)',
  });
  Object.assign(document.getElementById('chat-right-sidebar').style, {
    width: '320px', flex: 'none', display: 'flex', flexDirection: 'column', minHeight: '0',
  });
  /* The bubbles and the markdown inside them are the server's markup, so
     their rules go in one <style>: the old client's, near verbatim
     (js/message.js `ensureStyles`; the selection ring comes with the
     selection keys). Mine on the right, theirs on the left; the meta line
     small and muted; references, code, quotes, images and video as the
     renderer marks them. */
  var rules = document.createElement('style');
  rules.textContent = ''
    + '.chat-mp-history:focus { outline:none; }'
    + '.chat-msg { margin:0 0 12px; padding:8px 10px; border-radius:8px; max-width:88%; }'
    + '.chat-msg.mine { background:var(--cc-mine-bg); margin-left:auto; }'
    + '.chat-msg.theirs { background:var(--cc-theirs-bg); margin-right:auto; }'
    + '.chat-meta { font-size:11px; color:var(--cc-muted-fg); margin-bottom:3px; }'
    + '.chat-body { overflow-wrap:anywhere; }'
    + '.chat-body p:first-child { margin-top:0; }'
    + '.chat-body p:last-child { margin-bottom:0; }'
    + '.chat-body a.msg-ref { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:0.9em;'
    + ' background:var(--cc-accent-soft-bg); color:var(--cc-accent); padding:0 4px; border-radius:3px; text-decoration:none; }'
    + '.chat-body a.msg-ref:hover { background:var(--cc-accent-soft-hov); }'
    + '.chat-body pre { background:var(--cc-code-bg); padding:8px; border-radius:4px; overflow-x:auto; }'
    + '.chat-body pre.chat-quote { font-family:inherit; white-space:pre-wrap; overflow-wrap:anywhere;'
    + ' background:var(--cc-quote-bg); border-left:3px solid var(--cc-quote-border); border-radius:0 4px 4px 0;'
    + ' margin:6px 0; padding:6px 10px; color:var(--cc-body-muted-fg); overflow-x:visible; }'
    + '.chat-body img { max-width:100%; max-height:320px; width:auto; height:auto; display:block; margin:6px 0; border-radius:6px; }'
    + '.chat-body video { max-width:100%; max-height:480px; display:block; margin:6px 0; border-radius:6px; }'
    + '.chat-body table { border-collapse:collapse; }'
    + '.chat-body td, .chat-body th { border:1px solid var(--cc-border); padding:0 .4rem; }';
  document.head.appendChild(rules);

  /* The old client's time: the viewer's zone, as "Jan 2 · 3:04 PM". */
  function formatLocalTime(seconds) {
    var d = new Date(seconds * 1000);
    if (isNaN(d.getTime())) return '';
    var day = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(d);
    var time = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }).format(d);
    return day + ' · ' + time;
  }

  /* What the script adds to a bubble the server drew: mine or theirs, and
     its time as text. */
  function dress(bubble) {
    bubble.classList.add(bubble.dataset.by === me ? 'mine' : 'theirs');
    var t = bubble.querySelector('time.chat-time');
    if (t) t.textContent = formatLocalTime(Number(t.dataset.at));
  }

  /* The newest message drawn here: the stream sends only later ones, and
     one already here is never put in twice. */
  var newest = 0;
  function note(bubble) {
    var id = Number(bubble.dataset.id);
    if (id > newest) newest = id;
  }

  /* Caught up: the last bubble's bottom is in view (the old rule). */
  function caughtUp() {
    var last = bubbles.lastElementChild;
    while (last && !last.classList.contains('chat-msg')) last = last.previousElementSibling;
    if (!last) return true;
    return last.getBoundingClientRect().bottom <= history.getBoundingClientRect().bottom + 1;
  }

  /* A scroll the script makes is not the reader's; one the reader makes
     ends the image stabilizer. The script's own scrolls are a window that
     stays open until 150 ms pass with no scroll event, as the old client's
     (js/message_view.js, `armedScroll`): a flag cleared by the next event
     would stay set after a scroll that moved nothing, and the reader's own
     next scroll would be taken for the script's. */
  var ours = false;
  var oursTimer = null;
  var readerScrolled = false;
  function quiet() {
    if (oursTimer) clearTimeout(oursTimer);
    oursTimer = setTimeout(function () { ours = false; oursTimer = null; }, scrollQuietMs);
  }
  function scrollBy(fn) {
    ours = true;
    quiet();
    fn();
  }
  history.addEventListener('scroll', function () {
    if (ours) { quiet(); return; }
    readerScrolled = true;
  });
  function toBottom() {
    scrollBy(function () { history.scrollTop = history.scrollHeight; });
  }

  /* Images grow the transcript without a scroll event, so the bottom is
     taken again as each one loads, until the reader scrolls or 5 s pass. */
  function stabilize() {
    readerScrolled = false;
    var stopAt = Date.now() + stabilizeMs;
    function fire() {
      if (Date.now() > stopAt || readerScrolled) return;
      toBottom();
    }
    var imgs = bubbles.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) {
      if (!imgs[i].complete) {
        imgs[i].addEventListener('load', fire, { once: true });
        imgs[i].addEventListener('error', fire, { once: true });
      }
    }
    requestAnimationFrame(function () { fire(); requestAnimationFrame(fire); });
  }

  /* A fragment the server rendered, as its elements. */
  function parse(html) {
    var t = document.createElement('template');
    t.innerHTML = html;
    return t.content;
  }

  var drawn = bubbles.querySelectorAll('.chat-msg');
  for (var i = 0; i < drawn.length; i++) { dress(drawn[i]); note(drawn[i]); }
  toBottom();
  stabilize();

  var stream = new EventSource(root.dataset.stream);
  /* A new bubble, the server's HTML, from the stream or from a send's
     answer: put in once (its id is its message's, the newest so far), and
     followed only when the reader was caught up. The bubble now on the
     page, or null for one that was not a bubble. */
  function place(html) {
    var bubble = parse(html).firstElementChild;
    if (!bubble || !bubble.classList.contains('chat-msg')) return null;
    var here = document.getElementById(bubble.id);
    if (here) return here;
    if (Number(bubble.dataset.id) <= newest) return null;
    var stick = caughtUp();
    var empty = document.getElementById('chat-empty');
    if (empty) empty.remove();
    dress(bubble);
    bubbles.appendChild(bubble);
    note(bubble);
    if (stick) toBottom();
    return bubble;
  }
  stream.addEventListener('message', function (e) { place(e.data); });
  /* Further behind than the stream resends: the page drawn again. */
  stream.addEventListener('gap', function () { location.reload(); });
  /* A page restored from the back-forward cache has a dead stream. */
  window.addEventListener('pageshow', function (e) { if (e.persisted) location.reload(); });

  earlier.addEventListener('click', function () {
    var first = bubbles.querySelector('.chat-msg');
    if (!first || earlier.disabled) return;
    earlier.disabled = true;
    fetch(root.dataset.earlier + '?before=' + first.dataset.id).then(function (r) {
      return r.ok ? r.text() : null;
    }).then(function (html) {
      earlier.disabled = false;
      if (html === null) return;
      var page = parse(html).firstElementChild;
      if (!page) return;
      var height = history.scrollHeight;
      var older = page.querySelectorAll('.chat-msg');
      for (var j = 0; j < older.length; j++) {
        if (document.getElementById(older[j].id)) continue;
        dress(older[j]);
        bubbles.insertBefore(older[j], first);
      }
      scrollBy(function () { history.scrollTop += history.scrollHeight - height; });
      earlier.hidden = page.dataset.earlier !== '1';
    }, function () { earlier.disabled = false; });
  });
  /* What compose.js takes: put a bubble in; bring one into view; give
     the transcript the keyboard (focus without a scroll). */
  window.Feed = {
    place: place,
    reveal: function (bubble) { scrollBy(function () { bubble.scrollIntoView({ block: 'nearest' }); }); },
    focus: function () { history.focus({ preventScroll: true }); },
  };
})();
