// This script runs on the Recent page, which app/RecentFeed.roc builds and
// app/Script.roc serves. It is chat-client's js/recent.js, the page's tiles
// written by the server rather than built here.
//
// Each tile (.recent-tile, a link to its conversation) holds a lead (a DM's
// avatar, the other human's initial, or a channel's coloured bar), the place
// and topic, how long ago its last message was sent, and a one-line "Who:
// excerpt" preview. The script styles them (chat-client's styles, its colours
// palette.js's), colours each channel's bar by its name, and says each time
// as how long ago it was, again every 20 seconds, from its <time datetime>.
//
// The list names its live stream (data-stream). Each `tile` event is a
// conversation's tile after a new message: it takes the place of that
// conversation's tile, at the top, as chat-client's upsert did.
(function () {
  'use strict';
  var list = document.querySelector('.recent-list');

  // Identity colours for the channel bar, stable per channel name; they don't
  // flip with the theme.
  var CHANNEL_COLORS = [
    '#3faf8a', '#5b8def', '#e07a5f', '#9b72cf',
    '#e2b340', '#4ecdc4', '#f28482', '#7b8cde',
  ];

  var s = document.createElement('style');
  s.textContent = ''
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
    + '.recent-who { font-weight:600; color:var(--cc-meta-fg); }';
  document.head.appendChild(s);

  if (!list) throw new Error('recent.js: the page has no .recent-list');

  // A channel's name, from its tile's link: /chat/channel/<name>/<topic>.
  function channelOf(tile) {
    var parts = tile.getAttribute('href').split('/');
    return parts[2] === 'channel' ? parts[3] : '';
  }

  function colourBar(tile) {
    var bar = tile.querySelector('.recent-bar');
    if (!bar) return;
    var ch = channelOf(tile);
    var h = 0;
    for (var i = 0; i < ch.length; i++) h = ((h << 5) - h) + ch.charCodeAt(i);
    bar.style.background = CHANNEL_COLORS[Math.abs(h) % CHANNEL_COLORS.length];
  }
  list.querySelectorAll('.recent-tile').forEach(colourBar);

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
  // first: its message is the newest.
  function upsert(html) {
    var holder = document.createElement('template');
    holder.innerHTML = html;
    var tile = holder.content.querySelector('.recent-tile');
    if (!tile) return;
    var href = tile.getAttribute('href');
    list.querySelectorAll('.recent-tile').forEach(function (old) {
      if (old.getAttribute('href') === href) old.remove();
    });
    colourBar(tile);
    var ago = tile.querySelector('.recent-ago');
    if (ago) ago.textContent = humanize(ago.getAttribute('datetime'));
    list.insertBefore(tile, list.firstChild);
    var empty = document.querySelector('.empty');
    if (empty) empty.remove();
  }

  var events = new EventSource(list.getAttribute('data-stream'));
  events.addEventListener('tile', function (e) { upsert(e.data); });
})();
