// This script runs on a signed-in page, a conversation or any page with a
// .panel, which app/PageKit.roc builds and app/Script.roc serves. It styles the
// page's frame, which the server sends as structure and class names only, and
// adds the theme toggle.
//
// The frame is a top bar with the page's title on the left, the Browse, Recent and Invites links
// beside it as Gopher Chat's section links were (zig-server's chat_chrome.zig and top_bar.zig), and
// the Home link, the viewer's name and "Sign out" on the right, then the page's layout filling the rest of the
// window. In a narrow window the section links take a row of their own under the title. Only what
// the layout holds scrolls. On a conversation, feed.js styles the messages, and compose.js the
// compose box and how the two panes sit side by side; on any other page, panel.js styles the panel.
//
// The toggle is chat-client's (js/chat_theme.js): a button before the
// viewer's name showing where a click goes, 🌙 to dark and ☀️ to light.
// palette.js holds the colours and keeps the choice. The script makes the
// button itself, so a page without scripts shows no button that does
// nothing.
//
// The page's one breakpoint is here, as chat-client's js/viewport.js held
// it: a window at most 768 pixels wide, a phone's, is narrow. The root
// element has the class layout-narrow or layout-wide, so a script's style
// sheet says `html.layout-narrow .x` and never its own media query, and
// Viewport.onChange(f) calls f(narrow) now and at every crossing, for what a
// style sheet can't do (sidebar.js's drawer). A narrow page has less padding
// round its frame, and its fields' text is 16 pixels, so a phone doesn't zoom
// in on one it focuses.
//
// The notices are chat-client's js/notify.js, on the pages that have its
// strip as Gopher Chat's did (a conversation with a sidebar, and Recent): a
// page's stream passes on two events from the viewer's own key (feed.js,
// recent.js). `notice`, a link saying a human has come online (or that a
// new device signed in), goes to Notices.show; `message-notice`, a link to a
// message someone else wrote in one of the viewer's places (or the viewer in
// their own DM), to Notices.showUnlessHere. Each is
// shown in the top bar's notice line (.notice-strip, chat-client's
// #chat-notify), in place of the last one, and paints the tab's icon violet,
// whether or not the tab is in view, until the notice's link is followed or
// the notice dismissed, with no timer. A message's notice is the tab's violet
// (palette.js's noticeFg), a dot before it, so news of a message stands out;
// any other is the bar's muted text.
//
// A message on the topic being read says nothing in the strip, as notify.js
// said nothing (chat-client's js/notify.js:63 returned before both the strip
// and the favicon). But it does turn the tab violet when the page is hidden
// or not focused (Steve, 2026-11-20: "I need to know when Bob talks to me
// when I'm already talking to Bob! ... I could see excluding the status line,
// but we need the violet."), and that violet clears when the reader comes
// back to the page, where the message is in view; a violet from another
// topic's notice still clears only by its link or its ✕, as notify.js's did
// by its link alone (notify.js:66). notify.js drew the violet as a
// data: URL, which this site's policy refuses, so it is a file the server
// serves (app/Favicon.roc); and where notify.js cleared the tab to a blank
// icon, the site's own icon comes back. The <link> is made anew each time, as
// notify.js's was, since some browsers repaint only a new element.
window.Viewport = (function () {
  'use strict';
  var narrowQuery = window.matchMedia('(max-width:768px)');
  var callbacks = [];
  function reflect() {
    var root = document.documentElement;
    root.classList.toggle('layout-narrow', narrowQuery.matches);
    root.classList.toggle('layout-wide', !narrowQuery.matches);
  }
  reflect();
  narrowQuery.addEventListener('change', function () {
    reflect();
    callbacks.forEach(function (callback) { callback(narrowQuery.matches); });
  });
  return {
    isNarrow: function () { return narrowQuery.matches; },
    onChange: function (callback) { callbacks.push(callback); callback(narrowQuery.matches); },
  };
})();

// LocalTime.format(iso) is a time as chat-client wrote one: the viewer's
// zone, as "Nov 2 · 7:11 PM", or '' for a time that doesn't read. feed.js
// dates its messages by it, and search.js its answers.
window.LocalTime = (function () {
  'use strict';
  function format(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '';
    var day = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(d);
    var time = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }).format(d);
    return day + ' · ' + time;
  }
  return { format: format };
})();

window.Notices = (function () {
  'use strict';
  var strip = document.querySelector('.notice-strip');
  // The strip is economical with the page's height (Steve, 2026-11-20). In
  // a wide window it lives in the top bar, between the section links and the
  // viewer's name, so it spends no row of its own: one line of 12-pixel text
  // that takes the bar's spare width, cut with an ellipsis when it is longer.
  // A phone's bar has no spare width, so there it is a thin line of its own
  // along the bar's foot, 13-pixel text, with a ✕ that dismisses the notice
  // shown (a new one shows again), and no line at all when it says nothing.
  // The strip is the server's markup, so its rules are in the style sheet
  // below (`.notice-strip`).
  function paintTab(href) {
    var old = document.getElementById('favicon');
    if (old) old.remove();
    var link = document.createElement('link');
    link.id = 'favicon';
    link.rel = 'icon';
    link.href = href;
    document.head.appendChild(link);
  }
  // What the violet is for: a notice in the strip not yet followed or
  // dismissed (`strip`), a message on this page that came while the reader
  // was away (`here`). The tab is violet while either holds.
  var pending = { strip: false, here: false };
  function repaint() {
    if (pending.strip || pending.here) paintTab('/chat/assets/alert-icon.svg');
    else paintTab('/favicon.ico');
  }
  function alertTab() { pending.strip = true; repaint(); }
  function clearTab() { pending.strip = false; repaint(); }
  // Whether the reader is away from the page: it is hidden, or another
  // window or tab has the focus.
  function away() { return document.hidden || !document.hasFocus(); }
  function back() {
    if (!pending.here || away()) return;
    pending.here = false;
    repaint();
  }
  window.addEventListener('focus', back);
  document.addEventListener('visibilitychange', back);

  // The strip, saying `nodes`: a message's news (`message`) with its violet
  // dot, then the words, then the ✕ that empties the strip. Following a
  // link or dismissing clears the tab.
  function fill(nodes, message) {
    var words = document.createElement('span');
    words.className = 'notice-words';
    nodes.forEach(function (node) { words.appendChild(node); });
    words.querySelectorAll('a').forEach(function (link) { link.addEventListener('click', clearTab); });
    var dismiss = document.createElement('button');
    dismiss.type = 'button';
    dismiss.className = 'notice-dismiss';
    dismiss.textContent = '✕';
    dismiss.title = 'Dismiss this notice';
    dismiss.setAttribute('aria-label', 'Dismiss this notice');
    dismiss.addEventListener('click', function () { strip.replaceChildren(); clearTab(); });
    strip.replaceChildren();
    strip.classList.toggle('notice-message', message);
    if (message) {
      var dot = document.createElement('span');
      dot.className = 'notice-dot';
      strip.appendChild(dot);
    }
    strip.appendChild(words);
    strip.appendChild(dismiss);
  }
  // What the page was drawn saying (a DM's line of where the other human
  // is) gets its ✕ too.
  if (strip && strip.textContent.trim() !== '') fill(Array.prototype.slice.call(strip.childNodes), false);

  // The nodes of the server's HTML, `html`.
  function parsed(html) {
    var holder = document.createElement('template');
    holder.innerHTML = html;
    return Array.prototype.slice.call(holder.content.childNodes);
  }

  // A notice, the server's HTML (a link), shown in the strip in place of
  // the last one, and the tab painted.
  function show(html, message) {
    if (!strip) return;
    fill(parsed(html), message === true);
    alertTab();
  }

  // A message's notice, unless its link is this page: no point saying "new
  // message" about the topic being read. Then the tab alone turns violet,
  // if the reader is away. Both paths are read as the browser reads a URL,
  // so an escape in one is the same as in the other.
  function showUnlessHere(html) {
    var holder = document.createElement('template');
    holder.innerHTML = html;
    var link = holder.content.querySelector('a');
    if (link && new URL(link.getAttribute('href'), location.href).pathname === location.pathname) {
      if (away()) {
        pending.here = true;
        repaint();
      }
      return;
    }
    show(html, true);
  }

  return { show: function (html) { show(html, false); }, showUnlessHere: showUnlessHere };
})();

(function () {
  'use strict';
  var top = document.querySelector('.top-bar');
  var user = top && top.querySelector('.top-user');
  if (!user || !window.Palette) {
    throw new Error('chrome.js: the page has no .top-bar holding a .top-user, or palette.js did not run');
  }

  var s = document.createElement('style');
  s.textContent = [
    'html, body { height: 100%; }',
    'body { font-family: sans-serif; margin: 0; padding: 0; display: flex; flex-direction: column; }',
    '.top-bar { flex: none; background: var(--cc-top-bar-bg); border-bottom: 1px solid var(--cc-top-bar-border);' +
      ' padding: 8px 24px; display: flex; justify-content: space-between; align-items: baseline; gap: 14px; }',
    '.top-title { font-weight: bold; color: var(--cc-accent); min-width: 0; overflow-wrap: anywhere; }',
    '.top-title a { color: inherit; text-decoration: none; }',
    '.top-links { font-size: 13px; }',
    '.top-links a { text-decoration: none; }',
    '.top-links a:hover { text-decoration: underline; }',
    '.top-user { font-size: 13px; color: var(--cc-body-muted-fg); white-space: nowrap; margin-left: auto; }',
    '.top-user .viewer { font-weight: bold; }',
    // "Sign out" is a form, so it is a POST; its button reads as a link.
    '.top-user .sign-out { display: inline; margin: 0; }',
    '.top-user .sign-out button { background: none; border: none; padding: 0; font: inherit; color: var(--cc-accent);' +
      ' cursor: pointer; }',
    '.top-user .sign-out button:hover { text-decoration: underline; }',
    '.layout { flex: 1; min-height: 0; display: flex; gap: 20px; padding: 10px 24px; box-sizing: border-box; }',
    'a { color: var(--cc-accent); }',
    // The notice line. In the bar's spare width on a wide window; a
    // message's news violet, any other muted.
    '.notice-strip { margin: 0; font-size: 12px; line-height: 1.3; color: var(--cc-body-muted-fg); min-width: 0;' +
      ' flex: 1 1 0; display: flex; align-items: center; gap: 6px; }',
    '.notice-strip a { color: inherit; }',
    '.notice-strip.notice-message { color: var(--cc-notice-fg); font-weight: 600; }',
    '.notice-words { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }',
    '.notice-dot { flex: none; width: 7px; height: 7px; border-radius: 50%; background: var(--cc-notice-fg); }',
    '.notice-dismiss { flex: none; margin-left: auto; background: none; border: none; cursor: pointer; padding: 0 2px 0 8px;' +
      ' font-size: 12px; line-height: 1; color: var(--cc-body-muted-fg); }',
    'html.layout-wide .notice-dismiss { display: none; }',
    'html.layout-narrow body { height: 100dvh; }',
    'html.layout-narrow .top-bar { padding: 8px 12px; gap: 8px; align-items: center; }',
    'html.layout-narrow .top-bar { flex-wrap: wrap; }',
    'html.layout-narrow .top-title { flex: 1; }',
    // A narrow bar's second row: the section links. The empty ::after ends
    // the first row, so the second holds them whatever the title's length.
    // The notice line is a third row, edge to edge along the bar's foot,
    // ruled off above; none when it says nothing.
    'html.layout-narrow .top-bar { row-gap: 2px; }',
    'html.layout-narrow .top-bar::after { content: ""; order: 0; flex-basis: 100%; height: 0; }',
    'html.layout-narrow .top-links { order: 1; }',
    // A finger's target for each section link (Steve, 2026-11-21: "it's very
    // easy to fat-finger Recent in mobile"): 44 pixels tall, and wide enough
    // that the space between two links is the " · " alone. The negative left
    // margin keeps the words where they were; the negative bottom one lets
    // the targets take the bar's own padding, no further, so the notice line
    // under them isn't overlapped.
    'html.layout-narrow .top-links { margin: 0 0 -6px -8px; }',
    'html.layout-narrow .top-links a { display: inline-block; padding: 10px 8px; line-height: 24px; }',
    'html.layout-narrow .top-bar .notice-strip { order: 2; flex: 1 1 100%; margin: 4px -12px -8px; padding: 4px 12px;' +
      ' font-size: 13px; border-top: 1px solid var(--cc-top-bar-border); }',
    'html.layout-narrow .top-bar .notice-strip:empty { display: none; }',
    'html.layout-narrow .notice-dismiss { font-size: 14px; }',
    'html.layout-narrow .layout { padding: 8px; }',
    // A finger's target on a phone: the same words, more room round them.
    'html.layout-narrow .top-user .sign-out button { padding: 8px 4px; }',
    'html.layout-narrow input, html.layout-narrow textarea { font-size: 16px !important; }',
  ].join('\n');
  document.head.appendChild(s);

  var toggle = document.createElement('button');
  toggle.type = 'button';
  Object.assign(toggle.style, {
    background: 'none', border: 'none', cursor: 'pointer', fontSize: '16px', padding: '0 8px', verticalAlign: 'middle',
  });
  function paint() {
    var dark = Palette.current() === 'dark';
    var label = dark ? 'Switch to light theme' : 'Switch to dark theme';
    toggle.textContent = dark ? '☀️' : '🌙';
    toggle.title = label;
    toggle.setAttribute('aria-label', label);
  }
  toggle.addEventListener('click', function () { Palette.toggle(); paint(); });
  Palette.onChange(paint);
  paint();
  user.insertBefore(document.createTextNode(' · '), user.firstChild);
  user.insertBefore(toggle, user.firstChild);

  // "Sign out" carries this page's path as `next`, so a device signed in by a
  // code, which is asked first, has Cancel come back here (app/SignOutRoute.roc).
  var signOut = user.querySelector('.sign-out');
  if (signOut) {
    var next = document.createElement('input');
    next.type = 'hidden';
    next.name = 'next';
    next.value = location.pathname;
    signOut.appendChild(next);
  }
})();
