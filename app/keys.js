// This script runs on a conversation page, which app/ConversationPage.roc
// builds, and on Recent; app/Script.roc serves it. It is the page's one key
// table, Keys, which the scripts after it register their keys in.
//
// Keys.register({ key, cap, label, run, aliases, group }) takes the key's
// name (KeyboardEvent.key), what its button in the help shows (the name,
// when no cap is given), what it does, the function that does it, and any
// other keys that do the same, and adds one row to the keyboard help, the
// aliases named after the label in parentheses; `group: 'navigation'` puts
// the row under the Navigation heading at the end, in the order its keys
// are registered, which is theirs. The other rows sort here, whenever a key
// is registered (Steve, 2026-11-20: "err on the side of alphabetizing
// things that have no clear order"): the letter keys alphabetically, then
// `/` (search, essential), then the other symbols (`+`, `:`: "not as
// essential as the other keys and pretty easy to guess"), by their key. A
// key registered twice is an error, so two features never both think they
// own one. A key works when no text field has the focus and no modifier is
// held, as in chat-client.
//
// The help is Keys.help, an element compose.js puts in the closed compose
// rail, so the help lists exactly the keys that work, each as a button that
// does what the key does. Recent has no compose box, so its help is shown
// nowhere.
//
// Escape closes the innermost thing open, one a press, and does nothing
// while nothing is. Whatever opens (the compose box, a popup, a dialog, a
// popover, a menu) gives Keys.pushCloser the function that closes it as
// Escape should, and Keys.popCloser the same function when it closes,
// however it closes (its ✕, a click outside, a choice made in it). Escape
// runs the closer on top of the stack: the last opened of those still
// open. A closer may decline, as the compose box's does while it holds
// text; Escape then stops there, and closes nothing under it. A closer
// pushed twice, or popped when it isn't there, is an error, so a thing
// that forgets to pop is found. Escape is the stack's in any field, but
// not with a modifier held or while an input method is composing.
// Keys.showModal(dialog, closer) opens a modal <dialog> on the stack: the
// closer (the dialog's close, when none is given) is pushed, and popped
// when the dialog closes. The browser's own close request (a phone's back
// gesture) runs the closer too, so a dialog closes one way.
//
// The script styles what it builds, with one style sheet of its own. Its
// colours are palette.js's.
window.Keys = (function () {
  'use strict';
  var styleSheet = document.createElement('style');
  styleSheet.textContent = [
    '.keyhelp{margin-top:18px;font-size:13px;color:var(--cc-body-muted-fg)}',
    '.keyhelp-title{font-weight:bold;color:var(--cc-meta-fg);margin-bottom:7px}',
    '.keyhelp-row{margin:5px 0}',
    '.keyhelp-nav{margin-top:14px}',
    '.keyhelp-key{display:inline-block;min-width:1.1em;text-align:center;padding:1px 6px;' +
      'font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;color:var(--cc-meta-fg);background:var(--cc-bg);' +
      'border:1px solid var(--cc-border);border-bottom-width:2px;border-radius:4px;margin-right:7px;cursor:pointer}',
    '.keyhelp-key:hover{background:var(--cc-quote-bg);border-color:var(--cc-quote-border)}',
    '.keyhelp-key:active{background:var(--cc-mine-bg);border-bottom-width:1px;transform:translateY(1px)}',
  ].join('\n');
  document.head.appendChild(styleSheet);

  var keyhelp = document.createElement('div');
  keyhelp.className = 'keyhelp';
  var keyhelpTitle = document.createElement('div');
  keyhelpTitle.className = 'keyhelp-title';
  keyhelpTitle.textContent = 'Keyboard';
  keyhelp.appendChild(keyhelpTitle);
  var keyhelpRows = document.createElement('div');
  keyhelp.appendChild(keyhelpRows);
  // The navigation keys (arrows, Home, End, PgUp, PgDn) are the most
  // guessable, so they come last, under their own heading.
  var keyhelpNav = document.createElement('div');
  keyhelpNav.className = 'keyhelp-nav';
  keyhelpNav.hidden = true;
  var keyhelpNavTitle = document.createElement('div');
  keyhelpNavTitle.className = 'keyhelp-title';
  keyhelpNavTitle.textContent = 'Navigation';
  keyhelpNav.appendChild(keyhelpNavTitle);
  keyhelp.appendChild(keyhelpNav);

  var byKey = Object.create(null);
  function register(entry) {
    if (!entry || !entry.key || !entry.label || typeof entry.run !== 'function') {
      throw new Error('Keys.register: a key, a label and a run');
    }
    var keys = [entry.key].concat(entry.aliases || []);
    keys.forEach(function (key) {
      if (byKey[key]) throw new Error('Keys.register: "' + key + '" is registered twice');
      byKey[key] = entry;
    });
    var row = document.createElement('div');
    row.className = 'keyhelp-row';
    var keyButton = document.createElement('button');
    keyButton.type = 'button';
    keyButton.className = 'keyhelp-key';
    keyButton.textContent = entry.cap || entry.key;
    keyButton.title = entry.label;
    keyButton.addEventListener('click', function () { entry.run(); });
    row.appendChild(keyButton);
    var aliases = entry.aliases && entry.aliases.length ? ' (also ' + entry.aliases.join(' or ') + ')' : '';
    row.appendChild(document.createTextNode(' ' + entry.label + aliases));
    if (entry.group === 'navigation') {
      keyhelpNav.appendChild(row);
      keyhelpNav.hidden = false;
    } else if (entry.group) {
      throw new Error('Keys.register: "' + entry.group + '" is no group');
    } else {
      row.helpOrder = helpOrder(entry.key);
      var after = null;
      for (var next = keyhelpRows.firstChild; next; next = next.nextSibling) {
        if (next.helpOrder > row.helpOrder) { after = next; break; }
      }
      keyhelpRows.insertBefore(row, after);
    }
  }
  // A row's place in the help: a letter, then `/`, then any other key.
  function helpOrder(key) {
    var rank = /^[a-z]$/i.test(key) ? '0' : key === '/' ? '1' : '2';
    return rank + key;
  }

  document.addEventListener('keydown', function (e) {
    var focused = document.activeElement;
    if (focused && (focused.tagName === 'TEXTAREA' || focused.tagName === 'INPUT' || focused.isContentEditable)) return;
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    var entry = byKey[e.key];
    if (!entry) return;
    e.preventDefault();
    entry.run();
  });

  // The closers of what is open, innermost last.
  var closers = [];
  function pushCloser(closer) {
    if (typeof closer !== 'function') throw new Error('Keys.pushCloser: a function');
    if (closers.indexOf(closer) >= 0) throw new Error('Keys.pushCloser: a closer pushed twice');
    closers.push(closer);
  }
  function popCloser(closer) {
    var at = closers.indexOf(closer);
    if (at < 0) throw new Error('Keys.popCloser: a closer that is not on the stack');
    closers.splice(at, 1);
  }
  function showModal(dialog, closer) {
    var close = closer || function () { dialog.close(); };
    dialog.addEventListener('cancel', function (e) { e.preventDefault(); close(); });
    dialog.addEventListener('close', function () { popCloser(close); });
    pushCloser(close);
    dialog.showModal();
  }

  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape') return;
    if (e.isComposing || e.ctrlKey || e.metaKey || e.altKey || closers.length === 0) return;
    e.preventDefault();
    closers[closers.length - 1]();
  });

  return { register: register, help: keyhelp, pushCloser: pushCloser, popCloser: popCloser, showModal: showModal };
})();
