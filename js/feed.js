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
     - keeps the selection, the old view's: the arrows, Home/End and
       PgUp/PgDn (with its jump at an edge), scrolling and clicking select,
       the ring, and #msg-<id> in the URL after 700 ms (a hash the page
       arrived with kept until the reader moves); Home, and PgUp at the
       top, load earlier pages to reach the topic's first message;
     - takes an `edit` from the stream: the original's body redrawn,
       superseded, in place;
     - hands compose.js and quote.js `Feed`: place a bubble, reveal one,
       the selected one, focus the feed;
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
    + '.mv-selected { box-shadow:0 0 0 2px #ffcf3a; }'
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
    var mine = bubble.dataset.by === me;
    bubble.classList.add(mine ? 'mine' : 'theirs');
    /* Only one's own message is edited (the old buildMeta drew no "edit"
       on another's). */
    var edit = bubble.querySelector('.msg-edit');
    if (edit && !mine) edit.remove();
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
  var rafPending = false;
  history.addEventListener('scroll', function () {
    if (ours) { quiet(); return; }
    readerScrolled = true;
    if (rafPending) return;
    rafPending = true;
    requestAnimationFrame(function () { rafPending = false; syncSelectionToScroll(); });
  });
  function toBottom() {
    scrollBy(function () { history.scrollTop = history.scrollHeight; });
  }

  /* ---- the selection (the old js/message_view.js) ----
     One bubble is selected, ringed; the URL's #msg-<id> follows it after
     700 ms of rest (at once for a click or a jump to an end), so holding an
     arrow walks the ring one bubble a press and records only where it
     stops. Scrolling selects what comes into view; a click selects in the
     capture phase, before the bubble's own handlers run. */
  var settleDelay = 700, revealPadTop = 6, revealPadBottom = 48;
  var selected = null, settleTimer = null;
  function all() { return Array.prototype.slice.call(bubbles.querySelectorAll('.chat-msg')); }
  /* A link that arrived with a #msg-<id> keeps it until the reader moves:
     the deep link itself (going to that message) is a later feature. */
  var arrivedWithHash = /^#msg-/.test(location.hash);
  function record(bubble) {
    if (arrivedWithHash) return;
    window.history.replaceState({}, '', '#' + bubble.id);
  }
  function settle(bubble, immediate) {
    if (settleTimer) { clearTimeout(settleTimer); settleTimer = null; }
    if (selected) selected.classList.remove('mv-selected');
    selected = bubble;
    if (!bubble) return;
    bubble.classList.add('mv-selected');
    if (immediate) record(bubble);
    else settleTimer = setTimeout(function () { settleTimer = null; record(bubble); }, settleDelay);
  }
  function revealEl(el) {
    var hr = history.getBoundingClientRect(), r = el.getBoundingClientRect();
    if (r.top < hr.top + revealPadTop) {
      history.scrollTop += r.top - hr.top - revealPadTop;
    } else if (r.bottom > hr.bottom - revealPadBottom) {
      var delta = r.bottom - (hr.bottom - revealPadBottom);
      if (r.top - delta < hr.top + revealPadTop) delta = r.top - hr.top - revealPadTop;
      history.scrollTop += delta;
    }
  }
  /* The first bubble wholly in view; else the first whose top is in view;
     else the one straddling the top edge. */
  function selectionCandidate() {
    var hr = history.getBoundingClientRect(), beginning = null, straddler = null, els = all();
    for (var i = 0; i < els.length; i++) {
      var r = els[i].getBoundingClientRect();
      if (r.top >= hr.top - 1 && r.bottom <= hr.bottom + 1) return els[i];
      if (!beginning && r.top >= hr.top - 1 && r.top < hr.bottom) beginning = els[i];
      if (!straddler && r.top < hr.top && r.bottom > hr.top) straddler = els[i];
    }
    return beginning || straddler;
  }
  function syncSelectionToScroll() {
    /* A scroll of the script's own (a live append, an arrow, a reveal) in
       the same frame wins: the old rAF callback's `if(progScroll) return`. */
    if (ours) return;
    var c = selectionCandidate();
    if (c && c !== selected) settle(c, false);
  }
  history.addEventListener('click', function (e) {
    var bubble = e.target.closest && e.target.closest('.chat-msg');
    if (bubble) { arrivedWithHash = false; settle(bubble, true); }
  }, { capture: true });
  function moveCursor(delta) {
    arrivedWithHash = false;
    var els = all();
    if (!els.length) { history.scrollTop += delta * 40; return; }
    var pos = els.indexOf(selected);
    if (pos < 0) {
      pos = els.indexOf(selectionCandidate());
      if (pos < 0) pos = 0;
    } else {
      pos = Math.max(0, Math.min(els.length - 1, pos + delta));
    }
    var target = els[pos];
    settle(target, false);
    scrollBy(function () { revealEl(target); });
  }
  function cursorToExtreme(toBottom) {
    scrollBy(function () { history.scrollTop = toBottom ? history.scrollHeight : 0; });
    var els = all();
    if (els.length) settle(toBottom ? els[els.length - 1] : els[0], true);
  }
  /* The topic's real top: the old page held the whole transcript, so Home
     reached its first message. Here earlier pages load, one after another,
     until the first message is on the page, and then it is selected. */
  function toFirst() {
    arrivedWithHash = false;
    if (earlier.hidden) { cursorToExtreme(false); return; }
    loadEarlier().then(function (more) { if (more) toFirst(); else cursorToExtreme(false); });
  }
  /* A page down (or up) while the transcript can scroll; at its edge, a
     jump to the last (or first) bubble. */
  function pageNav(dir) {
    var canScroll = dir < 0 ? history.scrollTop > 0 : history.scrollTop + history.clientHeight < history.scrollHeight - 1;
    if (canScroll) history.scrollTop += dir * Math.max(40, history.clientHeight - 40);
    else if (dir > 0) cursorToExtreme(true);
    else toFirst();
  }
  /* A bubble brought to the middle of the view and selected (the old
     focusBubble: a "sent" notice's link). */
  function focusBubble(bubble) {
    scrollBy(function () {
      var cr = history.getBoundingClientRect(), er = bubble.getBoundingClientRect();
      history.scrollTop += (er.top + er.height / 2) - (cr.top + cr.height / 2);
    });
    settle(bubble, true);
  }
  /* The navigation keys: the old view's, not in the help panel (they are
     discoverable), registered so no other feature can take them. */
  [
    ['ArrowDown', function () { moveCursor(1); }], ['ArrowUp', function () { moveCursor(-1); }],
    ['Home', toFirst], ['End', function () { arrivedWithHash = false; cursorToExtreme(true); }],
    ['PageDown', function () { pageNav(1); }], ['PageUp', function () { pageNav(-1); }],
  ].forEach(function (k) { Keys.register({ key: k[0], label: k[0], hidden: true, run: k[1] }); });

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
  var last = all().pop();
  if (last) settle(last, true);
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
    if (stick) cursorToExtreme(true);
    return bubble;
  }
  stream.addEventListener('message', function (e) { place(e.data); });
  /* An edit by its author: the original, drawn again by the server
     superseded, its body put in place of the one here (the old
     markEdited), the bubble and its selection kept. Not here: nothing. */
  stream.addEventListener('edit', function (e) {
    var fresh = parse(e.data).firstElementChild;
    var here = fresh && fresh.id ? document.getElementById(fresh.id) : null;
    if (!here || !here.classList.contains('chat-msg')) return;
    var body = here.querySelector('.chat-body'), next = fresh.querySelector('.chat-body');
    if (body && next) here.replaceChild(next, body);
  });
  /* Further behind than the stream resends: the page drawn again. */
  stream.addEventListener('gap', function () { location.reload(); });
  /* A page restored from the back-forward cache has a dead stream. */
  window.addEventListener('pageshow', function (e) { if (e.persisted) location.reload(); });

  /* The page before the first bubble, from the server, put above it with
     the view kept where it was; a promise of whether pages come before it
     (false too when it did not load). */
  var loading = null;
  function loadEarlier() {
    if (loading) return loading;
    var first = bubbles.querySelector('.chat-msg');
    if (!first) return Promise.resolve(false);
    earlier.disabled = true;
    loading = fetch(root.dataset.earlier + '?before=' + first.dataset.id).then(function (r) {
      return r.ok ? r.text() : null;
    }).then(function (html) {
      if (html === null) return false;
      var page = parse(html).firstElementChild;
      if (!page) return false;
      var height = history.scrollHeight;
      var older = page.querySelectorAll('.chat-msg');
      for (var j = 0; j < older.length; j++) {
        if (document.getElementById(older[j].id)) continue;
        dress(older[j]);
        bubbles.insertBefore(older[j], first);
      }
      scrollBy(function () { history.scrollTop += history.scrollHeight - height; });
      earlier.hidden = page.dataset.earlier !== '1';
      return !earlier.hidden;
    }, function () { return false; }).then(function (more) {
      earlier.disabled = false;
      loading = null;
      return more;
    });
    return loading;
  }
  earlier.addEventListener('click', function () { loadEarlier(); });
  /* What compose.js and the later features take: put a bubble in; bring
     one to the middle and select it; the selected bubble; give the
     transcript the keyboard (focus without a scroll). */
  window.Feed = {
    place: place,
    reveal: focusBubble,
    selected: function () { return selected; },
    focus: function () { history.focus({ preventScroll: true }); },
  };
})();
