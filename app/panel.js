// This script runs on a signed-in human's page that is no conversation, such
// as Browse or the invites page, which app/PageKit.roc builds and app/Script.roc
// serves.
//
// The page's parts sit in a .panel, drawn as feed.js draws the messages pane: a
// card at most 600 pixels wide, and the only part of the page that scrolls.
// chrome.js styles the top bar above it and the layout around it. The script
// styles each element the server wrote there, and gives an invite's link or
// code its copy button. Its colours are palette.js's.
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
    var row = document.createElement('div');
    Object.assign(row.style, { display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: '8px', margin: '4px 0' });
    shown.parentNode.insertBefore(row, shown);
    row.appendChild(shown);
    Object.assign(shown.style, { flex: '1 1 0', minWidth: '0', margin: '0' });
    var button = document.createElement('button');
    button.type = 'button';
    button.setAttribute('aria-label', 'Copy the ' + what);
    button.title = 'Copy the ' + what;
    button.innerHTML = COPY_ICON;
    Object.assign(button.style, {
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
        button.innerHTML = COPY_ICON;
        return;
      }
      button.textContent = '✓';
      restore = setTimeout(function () { button.innerHTML = COPY_ICON; said.textContent = ''; }, 2000);
    }
    button.addEventListener('click', function () {
      writeClipboard(text).then(function () { tell('copied', false); }, function () {
        selectText(shown);
        tell('The browser would not let the page copy. The ' + what + ' is selected: copy it by hand ' +
          '(Ctrl+C, or ⌘+C on a Mac; on a phone, press and hold).', true);
      });
    });
  }
  panel.querySelectorAll('.invite-code').forEach(addCopyButton);

  // The panel takes the focus, so the keyboard scrolls it from the start.
  panel.tabIndex = -1;
  panel.focus();
})();
