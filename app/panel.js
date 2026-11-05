// This script runs on a signed-in human's page that is no conversation, such
// as Browse or the invites page, which app/Page.roc builds and app/Script.roc
// serves. The page works without it: its parts read top to bottom.
//
// The page's parts sit in a .panel, drawn as feed.js draws the messages pane: a
// card at most 600 pixels wide, and the only part of the page that scrolls.
// chrome.js styles the top bar above it and the layout around it. The script
// styles each element the server wrote there, and its colours are palette.js's.
(function () {
  'use strict';
  var panel = document.querySelector('.panel');
  if (!panel) throw new Error('panel.js: the page has no .panel');

  function styleAll(selector, style) {
    panel.querySelectorAll(selector).forEach(function (element) { Object.assign(element.style, style); });
  }

  Object.assign(panel.style, {
    flex: '1 1 auto', minWidth: '0', maxWidth: '600px', overflowY: 'auto', boxSizing: 'border-box',
    border: '1px solid var(--cc-border)', borderRadius: '8px', padding: '12px', background: 'var(--cc-card-bg)',
    outline: 'none',
  });
  styleAll('h1', {
    fontSize: '15px', margin: '14px 0 6px', paddingTop: '10px', borderTop: '1px solid var(--cc-border)',
  });
  styleAll('p', { margin: '4px 0', overflowWrap: 'anywhere' });
  styleAll('form', { display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: '8px', margin: '8px 0' });
  styleAll('form p', { margin: '0', fontSize: '13px', color: 'var(--cc-body-muted-fg)' });
  styleAll('input', {
    boxSizing: 'border-box', fontFamily: 'inherit', fontSize: '14px', padding: '3px 8px', width: '150px',
    background: 'var(--cc-bg)', color: 'var(--cc-fg)', border: '1px solid var(--cc-input-border)', borderRadius: '4px',
  });
  styleAll('button', {
    fontSize: '13px', padding: '4px 12px', background: 'var(--cc-mine-bg)', color: 'var(--cc-search-tok-fg)',
    border: '1px solid var(--cc-quote-border)', borderRadius: '6px', cursor: 'pointer',
  });
  styleAll('.invite-code', {
    fontFamily: 'ui-monospace, Menlo, Consolas, monospace', fontSize: '13px', padding: '8px',
    background: 'var(--cc-code-bg)', borderRadius: '4px', userSelect: 'all',
  });

  // The panel takes the focus, so the keyboard scrolls it from the start.
  panel.tabIndex = -1;
  panel.focus();
})();
