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
// recent.js). `notice`, a link saying a human has come online, goes to
// Notices.show; `message-notice`, a link to the topic of a message someone
// else wrote in one of the viewer's places, to Notices.showUnlessHere, which
// drops it on that topic's own page. Each is shown in the top bar's notice line
// (.notice-strip, chat-client's #chat-notify), in place of the last one, and
// paints the tab's icon violet, whether or not the tab is in view, until the
// notice's link is followed, with no timer. notify.js drew the violet as a
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

window.Notices = (function () {
  'use strict';
  var strip = document.querySelector('.notice-strip');
  // The strip is economical with the page's height (Steve, 2026-11-20): it
  // lives in the top bar, between the section links and the viewer's name,
  // so it spends no row of its own. It is one line of 12-pixel muted text
  // that takes the bar's spare width, cut with an ellipsis when it is longer.
  // In a narrow window it shares the section links' row, on its right (the
  // style sheet below, `.top-bar .notice-strip`).
  if (strip) {
    Object.assign(strip.style, {
      margin: '0', fontSize: '12px', lineHeight: '1.3', color: 'var(--cc-body-muted-fg)', overflow: 'hidden',
      textOverflow: 'ellipsis', whiteSpace: 'nowrap', minWidth: '0', flex: '1 1 0',
    });
  }
  function paintTab(href) {
    var old = document.getElementById('favicon');
    if (old) old.remove();
    var link = document.createElement('link');
    link.id = 'favicon';
    link.rel = 'icon';
    link.href = href;
    document.head.appendChild(link);
  }
  function alertTab() { paintTab('/chat/assets/alert-icon.svg'); }
  function clearTab() { paintTab('/favicon.ico'); }

  // A notice, the server's HTML (a link), shown in the strip in place of
  // the last one, and the tab painted. The link is the notices' colour, so
  // news stands out from the muted words the page was drawn with.
  function show(html) {
    if (!strip) return;
    strip.innerHTML = html;
    strip.querySelectorAll('a').forEach(function (link) {
      link.style.color = 'var(--cc-notify-fg)';
      link.addEventListener('click', clearTab);
    });
    alertTab();
  }

  // A message's notice, unless its link is this page: no point saying "new
  // message" about the topic being read. Both paths are read as the browser
  // reads a URL, so an escape in one is the same as in the other.
  function showUnlessHere(html) {
    var holder = document.createElement('template');
    holder.innerHTML = html;
    var link = holder.content.querySelector('a');
    if (link && new URL(link.getAttribute('href'), location.href).pathname === location.pathname) return;
    show(html);
  }

  return { show: show, showUnlessHere: showUnlessHere };
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
    'html.layout-narrow body { height: 100dvh; }',
    'html.layout-narrow .top-bar { padding: 8px 12px; gap: 8px; align-items: center; }',
    'html.layout-narrow .top-bar { flex-wrap: wrap; }',
    'html.layout-narrow .top-title { flex: 1; }',
    // A narrow bar's second row: the section links, then the notice line on
    // the right. The empty ::after ends the first row, so the second holds
    // the two whatever the title's length.
    'html.layout-narrow .top-bar { row-gap: 2px; }',
    'html.layout-narrow .top-bar::after { content: ""; order: 0; flex-basis: 100%; height: 0; }',
    'html.layout-narrow .top-links { order: 1; }',
    'html.layout-narrow .top-bar .notice-strip { order: 2; text-align: right; }',
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
  paint();
  user.insertBefore(document.createTextNode(' · '), user.firstChild);
  user.insertBefore(toggle, user.firstChild);
})();
