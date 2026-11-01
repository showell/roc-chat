/* keys.js: the page's one keyboard table (docs/design/browser-client.md,
   "Keys and help"). A feature registers its key here, and the one keydown
   listener dispatches it, with the old client's filter (chat-client's
   js/chat_help.js): no key while typing in a textarea, an input or an
   editable element, and none under Ctrl, Meta or Alt. A key registered
   twice fails at load, so two features can never both think they own it.
   The help panel (keyhelp.js) is built from this table: every key not marked
   `hidden` (the navigation keys, an alias), letters alphabetically, then
   `/ : +`, as the old panel ordered them. */
window.Keys = (function () {
  'use strict';
  var byKey = Object.create(null);
  /* Once the panel has read the table, it is closed: a key registered
     after would dispatch with no row in the help. */
  var frozen = false;

  /* register({key, label, run, hidden}): `run` is called on the key; it
     answers false when it did nothing (then the browser keeps the key, as
     the old client's did for a key that needs a selection and has none). */
  function register(entry) {
    if (!entry || !entry.key || typeof entry.run !== 'function') throw new Error('Keys.register: a key and a run');
    if (frozen) throw new Error('Keys.register: "' + entry.key + '" comes after the help panel was built');
    if (byKey[entry.key]) throw new Error('Keys.register: "' + entry.key + '" is registered twice');
    byKey[entry.key] = entry;
  }

  document.addEventListener('keydown', function (e) {
    var ae = document.activeElement;
    if (ae && (ae.tagName === 'TEXTAREA' || ae.tagName === 'INPUT' || ae.isContentEditable)) return;
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    var entry = byKey[e.key];
    if (entry && entry.run() !== false) e.preventDefault();
  });

  /* The panel's keys, in the old panel's order; the table closes here. */
  var tail = ['/', ':', '+'];
  function list() {
    frozen = true;
    var keys = Object.keys(byKey).filter(function (k) { return !byKey[k].hidden; });
    var letters = keys.filter(function (k) { return tail.indexOf(k) < 0; }).sort();
    var rest = tail.filter(function (k) { return keys.indexOf(k) >= 0; });
    return letters.concat(rest).map(function (k) { return byKey[k]; });
  }

  return { register: register, list: list };
})();
