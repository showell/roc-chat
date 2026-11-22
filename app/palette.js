// This script runs in the head of every page, which app/PageKit.roc builds and
// app/Script.roc serves. It sets the colours before the first paint,
// so a page never flashes the other theme.
//
// It also holds the page's body unseen until the body's scripts have run.
// They run at the end of the body, which a browser parses and paints before
// they come, so the page would show as its bare markup, unstyled, for as
// long as the scripts take to arrive and run. The body's scripts are
// parser-blocking, so DOMContentLoaded comes after the last of them, and the
// root then gets the class `scripted`, which shows the body. Until then the
// eye sees the page's background, in its theme. A script that
// throws, or doesn't load, still lets DOMContentLoaded come, so the page is
// never held for good. Unseen is `opacity`, not `visibility`, so a script
// can put the focus inside the body (compose.js, recent.js, panel.js)
// while it is held.
//
// A conversation's messages pane is held a step longer, until app/feed.js
// has placed it (`.messages.placed`): scrolled to the newest message, not
// showing its oldest at the top for a frame.
//
// The colours are chat-client's (js/colors.js), but for a code block's
// (syn...), which are GitHub's: one palette of CSS custom
// properties (--cc-...), light under :root and dark under html[data-theme="dark"]. The theme is
// the person's choice when localStorage's 'chat-theme' holds exactly 'light'
// or 'dark'. With no choice saved (none, or any other value, which is never
// written into the page) it is the system's, `prefers-color-scheme`: dark
// when that matches dark, light otherwise, and it follows the system live,
// so the page switches when the OS does. Gopher's chat-client was dark with
// no choice saved; the owner chose the system's (docs/design.md). Every other
// script styles its widgets with var(--cc-...). Palette.toggle() flips the
// theme and saves the choice, which then wins and ends the following;
// chrome.js wires it to the top bar's button, and Palette.onChange(fn) to
// repaint the button when the system flips the theme.
// noticeFg is Gopher Chat's violet, the tab's when news comes (#8a2be2,
// app/alert-icon.svg), lightened in the dark to read on its bar; chrome.js
// writes a message's notice in it.
//
// It is also the one home of what drags: a link or an image drags nowhere
// in the chat, so the browser's own drag of one (a ghost with no place to
// drop it, a Recent tile's above all) is cancelled at its dragstart, for
// every page and whatever a script adds later (docs/design.md, "Pages").
// A drag of selected text starts on its Text node and keeps it; an element
// marked draggable="true", a drag with a meaning, keeps its own; and a file
// dragged in from outside the page starts no drag here, so the compose box's
// drop is untouched. A click, a middle click, a long press and the context
// menu's "open in new tab" are not drags, and stay as they were.
document.addEventListener('dragstart', function (e) {
  var t = e.target;
  if (!t || t.nodeType !== 1 || t.closest('[draggable="true"]')) return;
  if (t.closest('a[href], img')) e.preventDefault();
});

window.Palette = (function () {
  'use strict';
  var STORAGE = 'chat-theme';

  // Each colour, one a line, as `name: [light, dark]`. The dark colours are
  // GitHub's, the bubbles a desaturated blue (the viewer's own) and a
  // desaturated warm grey (everyone else's).
  var COLOURS = {
    fg: ['#111', '#e6edf3'],
    mutedFg: ['#888', '#8b949e'],
    softMutedFg: ['#999', '#7d8590'],
    bodyMutedFg: ['#444', '#9aa4ae'],
    metaFg: ['#333', '#b8c0c8'],
    accent: ['#000080', '#58a6ff'],
    accentHover: ['#0000a0', '#79b8ff'],
    accentSoftBg: ['#eaeaff', '#1f2d4a'],
    accentSoftHov: ['#d8d8ff', '#28395e'],
    bg: ['#fff', '#0d1117'],
    cardBg: ['#fafafa', '#161b22'],
    mineBg: ['#e7e7ff', '#1c2433'],
    theirsBg: ['#f0f0e6', '#22221c'],
    quoteBg: ['#f6f6fb', '#161b22'],
    quoteBorder: ['#b9b9e0', '#3a3a5c'],
    codeBg: ['#f4f4ec', '#1a1f26'],
    codeStrapBg: ['#faf9f5', '#13171d'],
    codeFg: ['#222', '#e6edf3'],
    border: ['#ddd', '#30363d'],
    softBorder: ['#e0e0e0', '#272c33'],
    dialogBorder: ['#bbb', '#3a3f47'],
    inputBorder: ['#e3e3ef', '#30363d'],
    searchSelBg: ['#eef0ff', '#1f2d4a'],
    searchTokFg: ['#23235a', '#a8b1c5'],
    searchMarkBg: ['#ffe680', '#6b5210'],
    error: ['#b00020', '#ff7b72'],
    savedFg: ['#1a7a3a', '#56d364'],
    backdrop: ['rgba(0,0,0,0.4)', 'rgba(0,0,0,0.6)'],
    notifyFg: ['#1a5fb4', '#79b8ff'],
    noticeFg: ['#8a2be2', '#b48cff'],
    // The go colours (go...) are a call to action's: a bright green in each
    // theme (Steve, 2026-11-20: "Is there a brighter green we can use? The
    // current green is a bit dark."), its hover a step darker, and dark words
    // on it, as white ones on a green this bright fail WCAG AA. Against goFg,
    // goBg is 8.9:1 light and 10.5:1 dark, goHoverBg 6.6:1 and 8.1:1; savedFg
    // is a green for text, not a button's.
    goBg: ['#2ecc5a', '#3ddc6e'],
    goHoverBg: ['#27b04d', '#33c25f'],
    goFg: ['#111', '#0d1117'],
    topBarBg: ['#f0ede4', '#161b22'],
    topBarBorder: ['#c9bfa7', '#30363d'],
    presenceIdle: ['#3b82f6', '#58a6ff'],
    presenceOnline: ['#22c55e', '#3fb950'],
    lostBg: ['#fdd', '#3d1418'],
    lostFg: ['#600', '#ffb3ad'],
    selectRing: ['#ffcf3a', '#ffcf3a'],
    synComment: ['#6e7781', '#8b949e'],
    synLiteral: ['#0a3069', '#a5d6ff'],
    synKeyword: ['#cf222e', '#ff7b72'],
    synType: ['#953800', '#ffa657'],
  };
  var LIGHT = {};
  var DARK = {};
  Object.keys(COLOURS).forEach(function (k) {
    LIGHT[k] = COLOURS[k][0];
    DARK[k] = COLOURS[k][1];
  });

  function varName(camel) {
    return '--cc-' + camel.replace(/[A-Z]/g, function (c) { return '-' + c.toLowerCase(); });
  }
  function block(selector, palette) {
    var lines = [selector + ' {'];
    Object.keys(palette).forEach(function (k) { lines.push('  ' + varName(k) + ': ' + palette[k] + ';'); });
    lines.push('}');
    return lines.join('\n');
  }

  var saved = null;
  try { saved = localStorage.getItem(STORAGE); } catch (e) { saved = null; } // Private browsing: no saved theme.
  var chosen = saved === 'light' || saved === 'dark';
  var system = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  function systemTheme() { return system && system.matches ? 'dark' : 'light'; }
  document.documentElement.setAttribute('data-theme', chosen ? saved : systemTheme());
  var s = document.createElement('style');
  s.textContent = block(':root', LIGHT) + '\n' + block('html[data-theme="dark"]', DARK) + '\n'
    + 'body { background: var(--cc-bg); color: var(--cc-fg); }\n'
    + 'html:not(.scripted) body { opacity: 0; }\n'
    + '.messages:not(.placed) { opacity: 0; }\n';
  document.head.appendChild(s);
  document.addEventListener('DOMContentLoaded', function () {
    document.documentElement.classList.add('scripted');
  });

  function current() { return document.documentElement.getAttribute('data-theme') || 'light'; }
  var listeners = [];
  function onChange(fn) { listeners.push(fn); }
  // The system's flip, while no choice is saved.
  if (system && !chosen) {
    var follow = function () {
      if (chosen) return;
      document.documentElement.setAttribute('data-theme', systemTheme());
      listeners.forEach(function (fn) { fn(); });
    };
    if (system.addEventListener) system.addEventListener('change', follow);
    else if (system.addListener) system.addListener(follow);
  }
  function toggle() {
    var next = current() === 'dark' ? 'light' : 'dark';
    chosen = true;
    document.documentElement.setAttribute('data-theme', next);
    try { localStorage.setItem(STORAGE, next); } catch (e) { /* Private browsing: the choice lasts this page. */ }
    return next;
  }
  return { current: current, toggle: toggle, onChange: onChange };
})();
