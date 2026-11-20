// This script runs in the head of every page, which app/PageKit.roc builds and
// app/Script.roc serves. It sets the colours before the first paint,
// so a page never flashes the other theme.
//
// The colours are chat-client's (js/colors.js), but for a code block's
// (syn...), which are GitHub's: one palette of CSS custom
// properties (--cc-...), light under :root and dark under html[data-theme="dark"]. The theme is the one saved in
// localStorage under 'chat-theme', and dark when none is saved. Every other
// script styles its widgets with var(--cc-...). Palette.toggle() flips the
// theme and saves the choice; chrome.js wires it to the top bar's button.
// noticeFg is Gopher Chat's violet, the tab's when news comes (#8a2be2,
// app/alert-icon.svg), lightened in the dark to read on its bar; chrome.js
// writes a message's notice in it.
window.Palette = (function () {
  'use strict';
  var STORAGE = 'chat-theme';

  var LIGHT = {
    fg: '#111', mutedFg: '#888', softMutedFg: '#999', bodyMutedFg: '#444', metaFg: '#333',
    accent: '#000080', accentHover: '#0000a0', accentSoftBg: '#eaeaff', accentSoftHov: '#d8d8ff',
    bg: '#fff', cardBg: '#fafafa', mineBg: '#e7e7ff', theirsBg: '#f0f0e6',
    quoteBg: '#f6f6fb', quoteBorder: '#b9b9e0', codeBg: '#f4f4ec', codeStrapBg: '#faf9f5', codeFg: '#222',
    border: '#ddd', softBorder: '#e0e0e0', dialogBorder: '#bbb', inputBorder: '#e3e3ef',
    searchSelBg: '#eef0ff', searchTokFg: '#23235a', searchMarkBg: '#ffe680',
    error: '#b00020', savedFg: '#1a7a3a', backdrop: 'rgba(0,0,0,0.4)', notifyFg: '#1a5fb4', noticeFg: '#8a2be2',
    goBg: '#2ecc5a', goHoverBg: '#27b04d', goFg: '#111',
    topBarBg: '#f0ede4', topBarBorder: '#c9bfa7', presenceIdle: '#3b82f6', presenceOnline: '#22c55e',
    lostBg: '#fdd', lostFg: '#600', selectRing: '#ffcf3a',
    synComment: '#6e7781', synLiteral: '#0a3069', synKeyword: '#cf222e', synType: '#953800',
  };
  // The go colours (go...) are a call to action's: a bright green in each
  // theme (Steve, 2026-11-20: "Is there a brighter green we can use? The
  // current green is a bit dark."), its hover a step darker, and dark words
  // on it, as white ones on a green this bright fail WCAG AA. Against goFg,
  // goBg is 8.9:1 light and 10.5:1 dark, goHoverBg 6.6:1 and 8.1:1; savedFg
  // is a green for text, not a button's.
// GitHub's dark colours, the bubbles a desaturated blue (the viewer's own)
  // and a desaturated warm grey (everyone else's).
  var DARK = {
    fg: '#e6edf3', mutedFg: '#8b949e', softMutedFg: '#7d8590', bodyMutedFg: '#9aa4ae', metaFg: '#b8c0c8',
    accent: '#58a6ff', accentHover: '#79b8ff', accentSoftBg: '#1f2d4a', accentSoftHov: '#28395e',
    bg: '#0d1117', cardBg: '#161b22', mineBg: '#1c2433', theirsBg: '#22221c',
    quoteBg: '#161b22', quoteBorder: '#3a3a5c', codeBg: '#1a1f26', codeStrapBg: '#13171d', codeFg: '#e6edf3',
    border: '#30363d', softBorder: '#272c33', dialogBorder: '#3a3f47', inputBorder: '#30363d',
    searchSelBg: '#1f2d4a', searchTokFg: '#a8b1c5', searchMarkBg: '#6b5210',
    error: '#ff7b72', savedFg: '#56d364', backdrop: 'rgba(0,0,0,0.6)', notifyFg: '#79b8ff', noticeFg: '#b48cff',
    goBg: '#3ddc6e', goHoverBg: '#33c25f', goFg: '#0d1117',
    topBarBg: '#161b22', topBarBorder: '#30363d', presenceIdle: '#58a6ff', presenceOnline: '#3fb950',
    lostBg: '#3d1418', lostFg: '#ffb3ad', selectRing: '#ffcf3a',
    synComment: '#8b949e', synLiteral: '#a5d6ff', synKeyword: '#ff7b72', synType: '#ffa657',
  };

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
  document.documentElement.setAttribute('data-theme', saved || 'dark');
  var s = document.createElement('style');
  s.textContent = block(':root', LIGHT) + '\n' + block('html[data-theme="dark"]', DARK) + '\n'
    + 'body { background: var(--cc-bg); color: var(--cc-fg); }\n';
  document.head.appendChild(s);

  function current() { return document.documentElement.getAttribute('data-theme') || 'light'; }
  function toggle() {
    var next = current() === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    try { localStorage.setItem(STORAGE, next); } catch (e) { /* Private browsing: the choice lasts this page. */ }
    return next;
  }
  return { current: current, toggle: toggle };
})();
