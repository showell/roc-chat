/* keys.js: the page's one keyboard table (docs/design/browser-client.md,
   "Keys and help"). A feature registers its key here, and the one keydown
   listener dispatches it, with the old client's filter (chat-client's
   js/chat_help.js): no key while typing in a textarea, an input or an
   editable element, and none under Ctrl, Meta or Alt. A key registered
   twice fails at load, so two features can never both think they own it.
   The help panel built from this table comes with the selection keys. */
window.Keys = (function () {
  'use strict';
  var byKey = Object.create(null);

  /* register({key, label, run}): `run` is called on the key; it answers
     false when it did nothing (then the browser keeps the key). */
  function register(entry) {
    if (!entry || !entry.key || typeof entry.run !== 'function') throw new Error('Keys.register: a key and a run');
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

  return { register: register };
})();
