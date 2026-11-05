// This script runs on a conversation page, which app/Page.roc builds and
// app/Script.roc serves. It styles the page's frame, which the server
// sends as structure and class names only, and adds the theme toggle.
//
// The frame is a top bar with the conversation's title on the left and the Browse link and the
// viewer's name on the right, then the page's layout filling the rest of the window. Only the
// messages scroll; feed.js styles them, and compose.js the compose box and
// how the two panes sit side by side.
//
// The toggle is chat-client's (js/chat_theme.js): a button before the
// viewer's name showing where a click goes, 🌙 to dark and ☀️ to light.
// palette.js holds the colours and keeps the choice. The script makes the
// button itself, so a page without scripts shows no button that does
// nothing.
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
    '.top-user { font-size: 13px; color: var(--cc-body-muted-fg); white-space: nowrap; }',
    '.top-user .viewer { font-weight: bold; }',
    '.layout { flex: 1; min-height: 0; display: flex; gap: 20px; padding: 10px 24px; box-sizing: border-box; }',
    'a { color: var(--cc-accent); }',
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
