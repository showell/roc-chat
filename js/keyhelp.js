/* keyhelp.js: the keyboard help panel, built from the one key table
   (js/keys.js), as the old client's was (chat-client's js/chat_help.js,
   `renderKeyhelp`): titled "Keyboard", a row a key, each key a button that
   does what the key does, then its label. It sits in the right pane's
   closed panel, under "Open compose box", so it shows only while compose is
   closed. It loads after every feature has registered its keys. */
(function () {
  'use strict';
  var closed = document.getElementById('chat-closed-panel');
  if (!closed) return;

  var s = document.createElement('style');
  s.textContent = ''
    + '.chat-keyhelp { margin-top:18px; font-size:13px; color:var(--cc-body-muted-fg); }'
    + '.chat-keyhelp-title { font-weight:bold; color:var(--cc-meta-fg); margin-bottom:7px; }'
    + '.chat-key { margin:5px 0; }'
    + '.chat-keyhelp-key { display:inline-block; min-width:1.1em; text-align:center; padding:1px 6px;'
    + ' font-family:ui-monospace,Menlo,Consolas,monospace; font-size:12px; color:var(--cc-meta-fg); background:var(--cc-bg);'
    + ' border:1px solid var(--cc-border); border-bottom-width:2px; border-radius:4px; margin-right:7px; cursor:pointer; }'
    + '.chat-keyhelp-key:hover { background:var(--cc-quote-bg); border-color:var(--cc-quote-border); }'
    + '.chat-keyhelp-key:active { background:var(--cc-mine-bg); border-bottom-width:1px; transform:translateY(1px); }';
  document.head.appendChild(s);

  var box = document.createElement('div');
  box.className = 'chat-keyhelp';
  var title = document.createElement('div');
  title.className = 'chat-keyhelp-title';
  title.textContent = 'Keyboard';
  box.appendChild(title);
  Keys.list().forEach(function (entry) {
    var row = document.createElement('div');
    row.className = 'chat-key';
    var button = document.createElement('button');
    button.type = 'button';
    button.className = 'chat-keyhelp-key';
    button.textContent = entry.key;
    button.title = entry.label;
    button.addEventListener('click', function () { entry.run(); });
    row.appendChild(button);
    row.appendChild(document.createTextNode(' ' + entry.label));
    box.appendChild(row);
  });
  closed.appendChild(box);
})();
