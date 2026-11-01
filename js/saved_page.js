/* saved_page.js: the reading list's page, the glue around the saves the
   server drew (app/SavedPage.roc), in the old reading-list doc's look (a
   heading a save, its line of who and when and the way back, the body
   shown literally in the quote style the old `~~~ quote` fence gave it):
     - each save's time in the viewer's zone, "Jan 2 · 3:04 PM", as a
       bubble's (js/feed.js), since the server does not know the zone;
     - the styling, on the server's markup, in one <style>. */
(function () {
  'use strict';
  var s = document.createElement('style');
  s.textContent = ''
    + '.saved-page .app-body-wrap { max-width: 720px; }'
    + '.saved-title { font-size:18px; margin:18px 0 8px; }'
    + '.saved-entry { padding:10px 0 14px; border-bottom:1px solid var(--cc-border); }'
    + '.saved-note { font-size:15px; margin:0 0 4px; }'
    + '.saved-meta { font-size:12px; color:var(--cc-muted-fg); margin-bottom:6px; }'
    + '.saved-meta a { color:var(--cc-accent); }'
    + '.saved-body { white-space:pre-wrap; overflow-wrap:anywhere; font-size:13px; background:var(--cc-quote-bg);'
    + ' border-left:3px solid var(--cc-quote-border); padding:6px 10px; border-radius:4px; }'
    + '.saved-renote, .saved-delete { display:inline-block; margin:8px 8px 0 0; font-size:12px; }'
    + '.saved-renote input { font-size:12px; padding:2px 6px; width:16em; background:var(--cc-bg); color:var(--cc-fg);'
    + ' border:1px solid var(--cc-input-border); border-radius:4px; }'
    + '.saved-renote button, .saved-delete button { font-size:12px; }';
  document.head.appendChild(s);

  function formatLocalTime(seconds) {
    var d = new Date(seconds * 1000);
    if (isNaN(d.getTime())) return '';
    var day = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(d);
    var time = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }).format(d);
    return day + ' · ' + time;
  }
  Array.prototype.forEach.call(document.querySelectorAll('time.saved-time'), function (t) {
    var text = formatLocalTime(Number(t.dataset.at));
    if (text) t.textContent = text;
  });
})();
