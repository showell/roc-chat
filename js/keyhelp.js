/* keyhelp.js: the keyboard help panel, built from the one key table
   (js/keys.js), as the old client's was (chat-client's js/chat_help.js,
   `renderKeyhelp`): titled "Keyboard", a row a key, each key a button that
   does what the key does, then its label. It sits in the right pane's
   closed panel, under "Open compose box", so it shows only while compose is
   closed. It loads after every feature has registered its keys, and
   reading the table closes it (a later key would have no row).
   Its elements take their style inline; only what cannot be inlined (the
   buttons' :hover and :active) is a <style>. */
(function () {
  'use strict';
  var closed = document.getElementById('chat-closed-panel');
  if (!closed) throw new Error('keyhelp.js: no #chat-closed-panel, the right pane the panel goes in');

  var s = document.createElement('style');
  s.textContent = ''
    + '.chat-keyhelp-key:hover { background:var(--cc-quote-bg) !important; border-color:var(--cc-quote-border) !important; }'
    + '.chat-keyhelp-key:active { background:var(--cc-mine-bg) !important; border-bottom-width:1px !important; transform:translateY(1px); }';
  document.head.appendChild(s);

  var box = document.createElement('div');
  box.className = 'chat-keyhelp';
  Object.assign(box.style, { marginTop: '18px', fontSize: '13px', color: 'var(--cc-body-muted-fg)' });
  var title = document.createElement('div');
  title.className = 'chat-keyhelp-title';
  Object.assign(title.style, { fontWeight: 'bold', color: 'var(--cc-meta-fg)', marginBottom: '7px' });
  title.textContent = 'Keyboard';
  box.appendChild(title);
  Keys.list().forEach(function (entry) {
    var row = document.createElement('div');
    row.className = 'chat-key';
    Object.assign(row.style, { margin: '5px 0' });
    var button = document.createElement('button');
    button.type = 'button';
    button.className = 'chat-keyhelp-key';
    Object.assign(button.style, {
      display: 'inline-block', minWidth: '1.1em', textAlign: 'center', padding: '1px 6px',
      fontFamily: 'ui-monospace,Menlo,Consolas,monospace', fontSize: '12px', color: 'var(--cc-meta-fg)',
      background: 'var(--cc-bg)', border: '1px solid var(--cc-border)', borderBottomWidth: '2px',
      borderRadius: '4px', marginRight: '7px', cursor: 'pointer',
    });
    button.textContent = entry.key;
    button.title = entry.label;
    button.addEventListener('click', function () { entry.run(); });
    row.appendChild(button);
    row.appendChild(document.createTextNode(' ' + entry.label));
    box.appendChild(row);
  });
  closed.appendChild(box);
})();
