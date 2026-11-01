/* recent_page.js: the Recent page, the glue around the tiles the server drew
   (app/RecentPage.roc, app/Recent.roc). The old page's client, rebuilt
   (chat-client's js/recent.js):
     - each tile's age, "just now", "5m", "3h", "2d", from its data-ts
       (unix seconds), written again every 20 s; a tile with no message
       (data-ts 0) shows none;
     - a channel's bar, coloured by its name, the old eight colours;
     - the live stream: each new post's tile, drawn for this viewer by the
       server, replaces the tile with its key and goes to its place, newest
       first, below a tile of an equal time; the empty line goes;
     - a page restored from the back-forward cache is drawn again, its
       stream being dead;
     - the old styling, on the server's markup, in one <style>. */
(function () {
  'use strict';
  var list = document.querySelector('.recent-list');
  if (!list) return;

  var s = document.createElement('style');
  s.textContent = ''
    + '.recent-page .app-body-wrap { max-width: 720px; }'
    + '.recent-list { display:flex; flex-direction:column; }'
    + '.recent-tile { display:flex; align-items:flex-start; gap:10px; padding:10px 8px 10px 12px; text-decoration:none; color:inherit; border-radius:10px; }'
    + '.recent-tile:hover { background:var(--cc-quote-bg); }'
    + '.recent-tile:focus-visible { outline:2px solid var(--cc-accent); outline-offset:2px; }'
    + '.recent-lead { flex:none; width:32px; display:flex; justify-content:center; }'
    + '.recent-avatar { width:32px; height:32px; border-radius:50%; background:var(--cc-accent-soft-bg); color:var(--cc-accent);'
    + ' font-size:13px; font-weight:700; display:flex; align-items:center; justify-content:center; }'
    + '.recent-bar { width:8px; height:40px; margin-top:2px; border-radius:99px; }'
    + '.recent-body { flex:1; min-width:0; }'
    + '.recent-top { display:flex; align-items:baseline; gap:10px; }'
    + '.recent-context { flex:0 1 auto; min-width:0; font-size:13px; font-weight:600; color:var(--cc-body-muted-fg);'
    + ' white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }'
    + '.recent-topic { color:var(--cc-fg); font-weight:600; letter-spacing:-0.2px; }'
    + '.recent-dot { color:var(--cc-muted-fg); font-weight:600; }'
    + '.recent-ago { flex:none; font-size:12px; font-weight:500; font-variant-numeric:tabular-nums; color:var(--cc-muted-fg); }'
    + '.recent-title { min-width:0; font-size:15px; font-weight:600; letter-spacing:-0.2px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }'
    + '.recent-preview { margin-top:2px; font-size:13px; line-height:1.3; color:var(--cc-body-muted-fg); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }'
    + '.recent-who { font-weight:600; color:var(--cc-meta-fg); }';
  document.head.appendChild(s);

  /* A channel's identity colour, stable by its name, the same in either
     theme (the old client's). */
  var CHANNEL_COLORS = ['#3faf8a', '#5b8def', '#e07a5f', '#9b72cf', '#e2b340', '#4ecdc4', '#f28482', '#7b8cde'];
  function colour(tile) {
    /* A DM's initial, upper-cased as the old one (`toUpperCase`, any letter). */
    var avatar = tile.querySelector('.recent-avatar');
    if (avatar) avatar.textContent = avatar.textContent.toUpperCase();
    var bar = tile.querySelector('.recent-bar');
    if (!bar) return;
    var name = bar.dataset.channel || '', h = 0;
    for (var i = 0; i < name.length; i++) h = ((h << 5) - h) + name.charCodeAt(i);
    bar.style.background = CHANNEL_COLORS[Math.abs(h) % CHANNEL_COLORS.length];
  }

  /* The old ages: under a minute "just now", then minutes, hours, days. */
  function humanize(seconds) {
    var d = Date.now() - seconds * 1000;
    if (d < 60000) return 'just now';
    var m = Math.floor(d / 60000);
    if (m < 60) return m + 'm';
    var h = Math.floor(m / 60);
    if (h < 24) return h + 'h';
    return Math.floor(h / 24) + 'd';
  }
  function age(tile) {
    var ts = Number(tile.dataset.ts);
    var ago = tile.querySelector('.recent-ago');
    if (ago) ago.textContent = ts > 0 ? humanize(ts) : '';
  }
  function repaint() {
    var tiles = list.querySelectorAll('.recent-tile');
    for (var i = 0; i < tiles.length; i++) age(tiles[i]);
  }

  var drawn = list.querySelectorAll('.recent-tile');
  for (var i = 0; i < drawn.length; i++) { colour(drawn[i]); age(drawn[i]); }
  setInterval(repaint, 20000);

  /* Newest first; a tile goes above the first older one, so below any of
     an equal time (the old insert's strict `<`). */
  function insertSorted(tile) {
    var ts = Number(tile.dataset.ts);
    var tiles = list.querySelectorAll('.recent-tile');
    for (var j = 0; j < tiles.length; j++) {
      if (Number(tiles[j].dataset.ts) < ts) { list.insertBefore(tile, tiles[j]); return; }
    }
    list.appendChild(tile);
  }
  function upsert(html) {
    var t = document.createElement('template');
    t.innerHTML = html;
    var tile = t.content.firstElementChild;
    if (!tile || !tile.classList.contains('recent-tile')) return;
    var tiles = list.querySelectorAll('.recent-tile');
    for (var j = 0; j < tiles.length; j++) {
      if (tiles[j].dataset.key === tile.dataset.key) { tiles[j].remove(); break; }
    }
    colour(tile);
    age(tile);
    insertSorted(tile);
    var empty = document.getElementById('recent-empty');
    if (empty) empty.remove();
  }

  var stream = new EventSource('/chat/recent/stream');
  stream.addEventListener('message', function (e) { upsert(e.data); });
  window.addEventListener('pageshow', function (e) { if (e.persisted) location.reload(); });
})();
