// This script runs on a signed-in human's page that is no conversation, such
// as Browse or the invites page, which app/PageKit.roc builds and app/Script.roc
// serves.
//
// The page's parts sit in a .panel, drawn as feed.js draws the messages pane: a
// card at most 600 pixels wide (Browse's two panes, 960), centered in the
// window as Recent's is, and the only part of the page that scrolls.
// chrome.js styles the top bar above it and the layout around it. The script
// styles each element the server wrote there, and gives an invite's link or
// code its copy button. Its colours are palette.js's.
//
// A form's problem (.problem) is drawn as an error, in a tinted box. Quiet
// lines (.help) are small and muted. Browse's panes (.browse-panes) sit side
// by side on a desktop, one above the other on a phone, each a card whose
// first heading is its title; its topics (.topic-link) are rows, as Recent's
// tiles are. The reader's own "(you)" (.you) is quiet. On the invites page,
// a link just made (.invite-made) is a card, its link on one line with a
// "Copy link" button in the accent; each human's row (.invite-row) has its
// "New link" button at its right. That page answers a POST, so the script
// puts /invites in its place in the history: a reload is a plain GET, which
// makes no second invite and shows no link, and the link lives only in this
// page's memory, never in a URL, a log or a cookie.
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
    outline: 'none', marginLeft: 'auto', marginRight: 'auto',
  });
  if (panel.querySelector('.browse-panes')) panel.style.maxWidth = '960px';
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
  styleAll('.problem', {
    color: 'var(--cc-error)', background: 'color-mix(in srgb, var(--cc-error) 12%, transparent)',
    border: '1px solid color-mix(in srgb, var(--cc-error) 40%, transparent)', borderRadius: '6px',
    padding: '6px 10px', margin: '6px 0', fontSize: '14px',
  });
  styleAll('.help', { fontSize: '13px', color: 'var(--cc-body-muted-fg)' });
  styleAll('.help p', { margin: '2px 0' });
  styleAll('.you', { fontSize: '0.85em', fontWeight: '400', color: 'var(--cc-muted-fg)' });
  styleAll('.browse-panes', { display: 'flex', flexWrap: 'wrap', gap: '12px', alignItems: 'flex-start', marginTop: '10px' });
  styleAll('.browse-panes > div', {
    flex: '1 1 340px', minWidth: '0', border: '1px solid var(--cc-border)', borderRadius: '8px', padding: '4px 12px 10px',
  });
  styleAll('.browse-panes > div > h1:first-child', {
    fontSize: '13px', textTransform: 'uppercase', letterSpacing: '0.5px', color: 'var(--cc-muted-fg)',
    borderTop: 'none', paddingTop: '0', margin: '8px 0 2px',
  });
  styleAll('.topic-link', {
    display: 'block', padding: '3px 8px', margin: '0 -8px', borderRadius: '6px', textDecoration: 'none',
    color: 'var(--cc-fg)',
  });
  panel.querySelectorAll('.topic-link').forEach(function (link) { link.parentNode.style.margin = '0'; });
  var hover = document.createElement('style');
  hover.textContent = '.panel .topic-link:hover { background: color-mix(in srgb, var(--cc-fg) 7%, transparent); }' +
    ' .panel summary { cursor: pointer; color: var(--cc-muted-fg); font-size: 13px; margin: 10px 0 4px; }';
  document.head.appendChild(hover);
  styleAll('.invite-made', {
    border: '1px solid var(--cc-quote-border)', borderRadius: '8px', padding: '10px 12px', margin: '0 0 8px',
    background: 'var(--cc-accent-soft-bg)',
  });
  styleAll('.invite-row', {
    display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '12px', padding: '4px 0',
  });
  styleAll('.invite-row form', { margin: '0', flex: 'none' });
  styleAll('.invite-row button', { fontSize: '12px', padding: '2px 10px' });
  styleAll('.invite-code', {
    fontFamily: 'ui-monospace, Menlo, Consolas, monospace', fontSize: '13px', padding: '8px',
    background: 'var(--cc-code-bg)', borderRadius: '4px', userSelect: 'all',
  });
  // A device code, typed on a phone: large, its characters apart, the whole
  // of it selected by one tap.
  styleAll('.sign-in-code', {
    fontFamily: 'ui-monospace, Menlo, Consolas, monospace', fontSize: '32px', letterSpacing: '4px',
    padding: '8px 12px', background: 'var(--cc-code-bg)', borderRadius: '6px', userSelect: 'all',
  });

  // Each invite's link or code (the invites page's link, /agents' code) gets
  // a copy button after it. The script makes the button, so the server's
  // markup is the shown text alone. The button copies the text as the page
  // shows it, a link already absolute, and says so in place for 2 seconds:
  // ✓ and "copied". A clipboard the browser refuses leaves the text
  // selected, and the words say to copy it by hand.
  var COPY_ICON = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor"' +
    ' stroke-width="1.5" aria-hidden="true"><rect x="5.5" y="5.5" width="8" height="9" rx="1.5"/>' +
    '<path d="M10.5 3.5v-1a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h1"/></svg>';
  // On a touch screen the button is finger-sized.
  var buttonSide = window.matchMedia && window.matchMedia('(pointer: coarse)').matches ? '44px' : '32px';

  function selectText(element) {
    var range = document.createRange();
    range.selectNodeContents(element);
    var selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }
  function writeClipboard(text) {
    var clip = navigator.clipboard;
    if (!clip || !clip.writeText) return Promise.reject(new Error('no clipboard'));
    return clip.writeText(text);
  }
  function addCopyButton(shown) {
    var text = shown.textContent.trim();
    var what = /^https?:\/\//.test(text) ? 'link' : 'code';
    // A link is one line, scrolled sideways when it is longer than the card,
    // never broken inside its code; its button says what it does.
    var labeled = what === 'link';
    if (labeled) Object.assign(shown.style, { whiteSpace: 'nowrap', overflowX: 'auto', overflowWrap: 'normal' });
    var row = document.createElement('div');
    Object.assign(row.style, { display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: '8px', margin: '4px 0' });
    shown.parentNode.insertBefore(row, shown);
    row.appendChild(shown);
    Object.assign(shown.style, { flex: '1 1 0', minWidth: '0', margin: '0' });
    var button = document.createElement('button');
    button.type = 'button';
    button.setAttribute('aria-label', 'Copy the ' + what);
    button.title = 'Copy the ' + what;
    var face = labeled ? 'Copy link' : COPY_ICON;
    button.innerHTML = face;
    Object.assign(button.style, labeled ? {
      flex: '0 0 auto', height: buttonSide, padding: '0 14px', fontSize: '13px', cursor: 'pointer',
      background: 'var(--cc-accent)', color: 'var(--cc-bg)', border: '1px solid var(--cc-accent)', borderRadius: '6px',
    } : {
      flex: '0 0 auto', width: buttonSide, height: buttonSide, padding: '0', display: 'inline-flex',
      alignItems: 'center', justifyContent: 'center', fontSize: '15px', cursor: 'pointer',
      background: 'var(--cc-mine-bg)', color: 'var(--cc-search-tok-fg)',
      border: '1px solid var(--cc-quote-border)', borderRadius: '6px',
    });
    var said = document.createElement('span');
    said.setAttribute('role', 'status');
    Object.assign(said.style, { fontSize: '12px' });
    row.append(button, said);
    var restore = null;
    function tell(words, failed) {
      clearTimeout(restore);
      said.textContent = words;
      said.style.color = failed ? 'var(--cc-error)' : 'var(--cc-saved-fg)';
      if (failed) {
        button.innerHTML = face;
        return;
      }
      button.textContent = labeled ? '✓ Copied' : '✓';
      restore = setTimeout(function () { button.innerHTML = face; said.textContent = ''; }, 2000);
    }
    button.addEventListener('click', function () {
      writeClipboard(text).then(function () { tell(labeled ? '' : 'copied', false); }, function () {
        selectText(shown);
        tell('The browser would not let the page copy. The ' + what + ' is selected: copy it by hand ' +
          '(Ctrl+C, or ⌘+C on a Mac; on a phone, press and hold).', true);
      });
    });
  }
  panel.querySelectorAll('.invite-code').forEach(addCopyButton);
  if (panel.querySelector('.invite-made')) history.replaceState(null, '', '/invites');

  // The panel takes the focus, so the keyboard scrolls it from the start,
  // unless a script before it put the focus inside it (recent.js, on the
  // newest tile); the arrow keys still scroll the panel from there.
  panel.tabIndex = -1;
  if (!panel.contains(document.activeElement)) panel.focus();
})();
