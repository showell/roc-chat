// This script runs on the Recent page, which app/RecentFeed.roc builds and
// app/Script.roc serves. It is chat-client's js/recent.js, the page's tiles
// written by the server rather than built here.
//
// Each tile (.recent-tile, a link to its conversation) holds a lead (a DM's
// avatar, the other human's initial, or a channel's coloured bar), its place
// spelled out (.recent-where: "#general" or "DM with Apoorva", after a mark,
// the channel's colour or the DM's presence dot), the place and topic, how
// long ago its last message was sent, and a "Who: excerpt" preview.
//
// In a narrow window, a phone's, the tile is chat-client's: the lead, then
// the topic and the time, then a one-line preview, in a card at most 600
// pixels wide; the place spelled out is hidden. In a wide window the page
// breathes (Steve, 2026-11-20: "On the desktop, let's let it breathe"): the
// card is up to 920 pixels wide, and each tile is a row of columns, the place
// spelled out, then the topic over a two-line preview, then the time on the
// right; the lead, and the place repeated before the topic, are hidden.
// The whole row is the link, with a soft hover.
//
// The script styles the tiles (its colours palette.js's), colours each
// channel's bar and mark by its name, paints each DM's presence dot from its
// tile's data-presence (a hollow ring away, solid green online, as the
// sidebar's), and says each time as how long ago it was, again every 20
// seconds, from its <time datetime>.
//
// The list names its live stream (data-stream). Each `tile` event is a
// conversation's tile after a new message: it takes the place of that
// conversation's tile, at the top, as chat-client's upsert did, and glows
// for a moment so the eye finds it. A tile already at the top is replaced
// where it stands; when the pointer rests on a tile, the panel scrolls by
// what the new tile moved it, so the row under the pointer stays put. An
// `online` event, a human's id, fills their DMs' dots. The stream carries the
// viewer's notices too, `notice`, `device-notice` and `message-notice`, which chrome.js's
// Notices shows in the top bar, painting the tab, as Gopher Chat's Recent
// page did with notify.js.
(function () {
  'use strict';
  var list = document.querySelector('.recent-list');
  var panel = document.querySelector('.panel');

  // Identity colours for the channel bar, stable per channel name; they don't
  // flip with the theme.
  var CHANNEL_COLORS = [
    '#3faf8a', '#5b8def', '#e07a5f', '#9b72cf',
    '#e2b340', '#4ecdc4', '#f28482', '#7b8cde',
  ];
  var WIDE = 'html.layout-wide ';

  var s = document.createElement('style');
  s.textContent = ''
    + '.panel { margin-left:auto; margin-right:auto; }'
    + '.recent-list { display:flex; flex-direction:column; }'
    + '.recent-tile { display:flex; align-items:flex-start; gap:10px;'
    +              ' padding:10px 8px 10px 12px; text-decoration:none;'
    +              ' color:inherit; border-radius:10px; }'
    + '.recent-tile:hover { background:var(--cc-quote-bg); }'
    + '.recent-tile:focus-visible { outline:2px solid var(--cc-accent); outline-offset:2px; }'
    + '.recent-lead { flex:none; width:32px; display:flex; justify-content:center; }'
    + '.recent-avatar { width:32px; height:32px; border-radius:50%;'
    +                ' background:var(--cc-accent-soft-bg); color:var(--cc-accent);'
    +                ' font-size:13px; font-weight:700;'
    +                ' display:flex; align-items:center; justify-content:center; }'
    + '.recent-bar { display:block; width:8px; height:40px; margin-top:2px; border-radius:99px; }'
    + '.recent-where { display:none; }'
    + '.recent-body { display:block; flex:1; min-width:0; }'
    + '.recent-top { display:flex; align-items:baseline; gap:10px; }'
    + '.recent-context { flex:0 1 auto; min-width:0; font-size:13px; font-weight:600;'
    +                 ' color:var(--cc-body-muted-fg); white-space:nowrap;'
    +                 ' overflow:hidden; text-overflow:ellipsis; }'
    + '.recent-topic { color:var(--cc-fg); font-weight:600; letter-spacing:-0.2px; }'
    + '.recent-dot { color:var(--cc-muted-fg); font-weight:600; white-space:pre; }'
    + '.recent-ago { flex:none; font-size:12px; font-weight:500;'
    +             ' font-variant-numeric:tabular-nums; color:var(--cc-muted-fg); }'
    + '.recent-title { min-width:0; font-size:15px; font-weight:600;'
    +               ' letter-spacing:-0.2px; white-space:nowrap;'
    +               ' overflow:hidden; text-overflow:ellipsis; }'
    + '.recent-preview { display:block; margin-top:2px; font-size:13px; line-height:1.3;'
    +                 ' color:var(--cc-body-muted-fg); white-space:nowrap;'
    +                 ' overflow:hidden; text-overflow:ellipsis; }'
    + '.recent-who { font-weight:600; color:var(--cc-meta-fg); }'
    // A newly arrived tile glows, then fades back.
    + '@keyframes recent-arrive { from { background:var(--cc-search-mark-bg); } to { background:transparent; } }'
    + '.recent-tile.recent-fresh { animation:recent-arrive 2.5s ease-out; }'
    // The wide window's columns. panel.js sets the card's 600 pixels on the
    // element itself, so this wider one needs !important to win.
    + WIDE + '.panel { max-width:920px !important; padding:8px 12px !important; }'
    + WIDE + '.recent-tile { display:grid; grid-template-columns:200px minmax(0,1fr) auto;'
    +        ' column-gap:24px; row-gap:4px; align-items:baseline; padding:14px 16px;'
    +        ' border-bottom:1px solid var(--cc-soft-border); border-radius:8px; }'
    + WIDE + '.recent-tile:hover { background:var(--cc-mine-bg); }'
    + WIDE + '.recent-lead, ' + WIDE + '.recent-place, ' + WIDE + '.recent-dot { display:none; }'
    + WIDE + '.recent-body, ' + WIDE + '.recent-top { display:contents; }'
    + WIDE + '.recent-where { display:block; grid-column:1; grid-row:1 / span 2; align-self:start;'
    +        ' font-size:14px; font-weight:600; color:var(--cc-fg); white-space:nowrap;'
    +        ' overflow:hidden; text-overflow:ellipsis; }'
    + WIDE + '.recent-mark { display:inline-block; vertical-align:middle; margin:-2px 8px 0 0;'
    +        ' width:10px; height:10px; box-sizing:border-box; }'
    + WIDE + '.recent-context, ' + WIDE + '.recent-title { grid-column:2; grid-row:1;'
    +        ' font-size:15px; font-weight:600; color:var(--cc-fg); }'
    + WIDE + '.recent-ago { grid-column:3; grid-row:1; justify-self:end; font-size:13px; }'
    + WIDE + '.recent-preview { grid-column:2 / span 2; grid-row:2; margin-top:0; font-size:14px;'
    +        ' line-height:1.45; white-space:normal; overflow-wrap:anywhere; display:-webkit-box;'
    +        ' -webkit-line-clamp:2; -webkit-box-orient:vertical; }';
  document.head.appendChild(s);

  if (!list) throw new Error('recent.js: the page has no .recent-list');

  // A channel's name, from its tile's link: /chat/channel/<name>/<topic>.
  function channelOf(tile) {
    var parts = tile.getAttribute('href').split('/');
    return parts[2] === 'channel' ? parts[3] : '';
  }

  // A channel's bar and mark take its colour; a DM's mark is its other
  // human's presence dot.
  function paintMarks(tile) {
    var mark = tile.querySelector('.recent-mark');
    var ch = channelOf(tile);
    if (ch) {
      var h = 0;
      for (var i = 0; i < ch.length; i++) h = ((h << 5) - h) + ch.charCodeAt(i);
      var colour = CHANNEL_COLORS[Math.abs(h) % CHANNEL_COLORS.length];
      var bar = tile.querySelector('.recent-bar');
      if (bar) bar.style.background = colour;
      if (mark) Object.assign(mark.style, { background: colour, borderRadius: '3px' });
    } else if (mark && tile.hasAttribute('data-person')) {
      var online = tile.getAttribute('data-presence') === 'online';
      Object.assign(mark.style, {
        borderRadius: '50%',
        border: '1.5px solid ' + (online ? 'var(--cc-presence-online)' : 'var(--cc-presence-idle)'),
        background: online ? 'var(--cc-presence-online)' : 'transparent',
      });
      mark.title = online ? 'online' : 'away';
    }
  }
  list.querySelectorAll('.recent-tile').forEach(paintMarks);

  // A human come online: each of their DMs' dots filled.
  function markOnline(person) {
    list.querySelectorAll('.recent-tile[data-person]').forEach(function (tile) {
      if (tile.getAttribute('data-person') !== person) return;
      tile.setAttribute('data-presence', 'online');
      paintMarks(tile);
    });
  }

  function humanize(iso) {
    var d = Date.now() - new Date(iso).getTime();
    if (d < 60000) return 'just now';
    var m = Math.floor(d / 60000);
    if (m < 60) return m + 'm';
    var h = Math.floor(m / 60);
    if (h < 24) return h + 'h';
    return Math.floor(h / 24) + 'd';
  }

  function paintAges() {
    list.querySelectorAll('.recent-ago').forEach(function (ago) {
      ago.textContent = humanize(ago.getAttribute('datetime'));
    });
  }
  paintAges();
  setInterval(paintAges, 20000);

  // A new tile replaces its conversation's, matched by its link, and goes
  // first: its message is the newest. A tile already first is replaced where
  // it stands. The tile under the pointer, if any, is kept where it was on
  // the screen, the panel scrolling by what the move shifted it.
  function upsert(html) {
    var holder = document.createElement('template');
    holder.innerHTML = html;
    var tile = holder.content.querySelector('.recent-tile');
    if (!tile) throw new Error('recent.js: a tile event holds no .recent-tile');
    paintMarks(tile);
    var ago = tile.querySelector('.recent-ago');
    if (ago) ago.textContent = humanize(ago.getAttribute('datetime'));
    var hovered = list.querySelector('.recent-tile:hover');
    var hoveredTop = hovered ? hovered.getBoundingClientRect().top : 0;
    var href = tile.getAttribute('href');
    var first = list.querySelector('.recent-tile');
    if (first && first.getAttribute('href') === href) {
      list.replaceChild(tile, first);
    } else {
      list.querySelectorAll('.recent-tile').forEach(function (old) {
        if (old.getAttribute('href') === href) old.remove();
      });
      list.insertBefore(tile, list.firstChild);
    }
    if (hovered && hovered.isConnected && panel) {
      panel.scrollTop += hovered.getBoundingClientRect().top - hoveredTop;
    }
    tile.classList.add('recent-fresh');
    tile.addEventListener('animationend', function () { tile.classList.remove('recent-fresh'); }, { once: true });
    var empty = document.querySelector('.empty');
    if (empty) empty.remove();
  }

  var events = new EventSource(list.getAttribute('data-stream'));
  events.addEventListener('tile', function (e) { upsert(e.data); });
  events.addEventListener('online', function (e) { markOnline(e.data); });
  events.addEventListener('notice', function (e) { Notices.show(e.data); });
  events.addEventListener('device-notice', function (e) { Notices.showNews(e.data); });
  events.addEventListener('message-notice', function (e) { Notices.showUnlessHere(e.data); });
})();
