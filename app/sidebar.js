// This script runs on a conversation page that has a sidebar, which
// app/Sidebar.roc builds and app/Script.roc serves. The server writes the
// sidebar whole, in two groups, Channels and DMs (.sidebar-section,
// data-group), each under its heading, the group of the page's own topic
// first (DMs first on a DM's page); in each, app/SidebarOrder.roc's
// order: the page's own place first, then the others newest first, each
// place's topics under it as links, newest first, the current topic marked,
// and the form that starts a topic at the end of each place. This script
// gives it chat-client's behaviour (js/chat_left_sidebar.js), without that
// rail's pinning or dragging. It never moves a place: the order is the
// server's, as the page was drawn.
//
// Its look is Steve's, not chat-client's: like a good referee, it should
// feel invisible until you need it. On the rail it is a box with a thin
// border and rounded corners, as the message list is, the same height as
// the message list and the compose box beside it. The two groups are
// divided by a thin line, each headed by its name, small and muted ("DMs"
// kept in its own case, so no capitals). The levels are a tree: a heading
// starts INSET from the box's left edge, and each level below starts one
// STEP further in, so a place's triangle sits under its group's name and a
// topic under its place's name. Every row spans the box's width, its indent
// its own left padding, so a row's tint reaches both edges. Topics are a
// quiet grey, and a topic pointed at shows by its text's colour, never a
// fill. The current topic alone is drawn otherwise: bold, in the page's
// own text colour, on a tinted row with a slim accent bar at the box's left
// edge. The rows have room to breathe; a group or place that runs long
// collapses, so going below the fold is fine.
//
// Collapsing: a standard disclosure triangle before each group's heading
// and each place's name, ▾ open and ▸ collapsed, collapses or opens it, by
// a click or by Enter or Space on it. A group's heading, and a channel's
// name, do the same; a DM's name opens instead the card about its person
// (sidebar-popups.js). A group starts open, and a place as the server says
// (data-opening): `open`, `collapsed`, or `always`, the page's own place,
// which opens on every load. Once a person opens or collapses a group or a
// place, their choice is kept across reloads (localStorage, by the group's
// data-group or the place's data-section) and wins over `open` and
// `collapsed`. A group's heading is a row whose name takes the room left, so
// a small menu button can be added at its right end later.
//
// The DMs group shows only the people the reader is talking to
// (app/DmShortlist.roc); the server writes the rest last in the group,
// under one row, "N more people…" (.sidebar-more), and this script hides
// them and makes the row open the people popup (sidebar-popups.js).
//
// Presence, chat-client's: a DM with another human (data-person) has a dot
// before its name, a hollow ring while they are away and solid green while
// they are online (data-presence). The page's stream (feed.js) passes on
// `online` from the viewer's own key, a human's id, which fills their dot
// (Sidebar.markOnline). A dot never empties while the page is open: as in
// chat-client, the next page drawn says who is still online. The notices
// above the page, and the tab's violet icon, are chrome.js's (Notices).
//
// In a window wider than 768 pixels the sidebar is a rail 224 pixels wide on
// the left of the layout, which keeps only 12 pixels of room at its left
// for it. In a narrow window (chrome.js's Viewport) it is a
// drawer, as chat-client's was (js/chrome_drawer.js and
// js/chat_responsive.js): the server's toggle button moves to the start of
// the top bar as a ☰, and a tap slides the sidebar in from the left over the
// page, a backdrop dimming the rest. A tap on the backdrop, Escape, the ☰
// again, or choosing a topic closes it, and so does widening the window. Its
// links and buttons are larger, for a finger.
//
// Sidebar.addTopic(section, label, url) adds a topic to the place whose
// data-section is `section`, built as the server's rows are. The stream's
// `topic-added` event, sent to each human of a place on a topic's first
// message (app/TopicAdded.roc), calls it through Sidebar.topicAdded: its data
// is Gopher's three fields, a line each, the place's path, the topic and its
// page. A new topic's first message is its place's newest, so it goes first
// among the place's topics, as the server would order it; no other row
// moves, and a collapsed place stays collapsed. As chat-client's
// upsertSession, a topic already listed is left, and a place this sidebar
// doesn't list is ignored.
//
// A new topic is rare, so its form stays out of sight. The server writes each
// place's form after its topics, and before them a button, "New topic in"
// and the place's name; this script takes the form out of the sidebar and
// shows the button as a small "+" beside the place's name, its words kept as
// its label. The "+" opens the place's new-topic popup (sidebar-popups.js).
//
// It finds every part by app/PageContract.roc's classes, and styles each on
// the DOM itself; its colours are palette.js's.
window.Sidebar = (function () {
  'use strict';
  var sidebar = document.querySelector('.sidebar');
  var toggle = document.querySelector('.sidebar-toggle');
  var topBar = document.querySelector('.top-bar');
  if (!sidebar || !toggle || !topBar) throw new Error('sidebar.js: the page has no .sidebar, .sidebar-toggle or .top-bar');
  if (!window.Viewport) throw new Error('sidebar.js: chrome.js runs first, and gives Viewport');
  if (!window.SidebarPopups) throw new Error('sidebar.js: sidebar-popups.js runs first, and gives SidebarPopups');

  function styleAll(selector, style) {
    sidebar.querySelectorAll(selector).forEach(function (element) { Object.assign(element.style, style); });
  }

  // The tree's measures, in pixels: a heading's indent from the box's left
  // edge, the step of each level below it (a triangle's width and the gap
  // after it), a triangle's width, and the room each row keeps at its right.
  var INSET = 10;
  var TRIANGLE = 20;
  var GAP = 4;
  var STEP = TRIANGLE + GAP;
  var RIGHT = 8;
  var TOPIC_INDENT = INSET + 2 * STEP;
  // Whether the window is narrow, the sidebar a drawer: Viewport says, below.
  var narrow = Viewport.isNarrow();

  Object.assign(sidebar.style, { overflowY: 'auto', boxSizing: 'border-box', lineHeight: '1.35' });
  styleAll('.sidebar-section', { margin: '0 0 14px' });
  styleAll('.sidebar-section:last-child', { marginBottom: '0' });
  styleAll('.sidebar-section + .sidebar-section', { borderTop: '1px solid var(--cc-soft-border)', paddingTop: '10px' });
  styleAll('.sidebar-section-name', {
    margin: '0', flex: '1', minWidth: '0', fontSize: '12px', fontWeight: '600', letterSpacing: '0.03em',
    color: 'var(--cc-muted-fg)', cursor: 'pointer', userSelect: 'none',
  });
  styleAll('.sidebar-place', { marginBottom: '6px' });
  styleAll('.sidebar-place-name', {
    display: 'flex', alignItems: 'center', gap: '6px', margin: '0', flex: '1', minWidth: '0', fontWeight: 'normal',
    color: 'var(--cc-meta-fg)', cursor: 'pointer', userSelect: 'none', overflowWrap: 'anywhere',
  });
  // The page's own place in the page's text colour, not bold: the current
  // topic under it is what stands out.
  styleAll('.sidebar-place[data-opening="always"] .sidebar-place-name', { color: 'var(--cc-fg)' });
  // The "+": light until pointed at, and a finger's size in the drawer.
  styleAll('.sidebar-new-topic', {
    flex: 'none', background: 'none', border: 'none', borderRadius: '4px', cursor: 'pointer',
    color: 'var(--cc-muted-fg)', fontSize: '16px', lineHeight: '1', fontFamily: 'inherit',
  });
  styleAll('form', { margin: '4px 0 0', display: 'flex', flexDirection: 'column', gap: '4px' });
  styleAll('form p', { margin: '0', fontSize: '12px', color: 'var(--cc-muted-fg)' });
  styleAll('input', {
    boxSizing: 'border-box', width: '100%', fontFamily: 'inherit', fontSize: '12px', padding: '2px 6px',
    background: 'var(--cc-bg)', color: 'var(--cc-fg)', border: '1px solid var(--cc-input-border)', borderRadius: '4px',
  });
  styleAll('form button', {
    alignSelf: 'flex-start', fontSize: '12px', padding: '2px 10px', background: 'var(--cc-mine-bg)',
    color: 'var(--cc-search-tok-fg)', border: '1px solid var(--cc-quote-border)', borderRadius: '6px', cursor: 'pointer',
  });

  // A list of topics, and each row in it, the box's width, its name two
  // steps in: a topic quiet grey, shown by its text's colour when pointed
  // at; the current topic bold in the page's text colour, on a tinted row
  // with a 3-pixel accent bar at the box's left edge (an inset shadow, so
  // no row's text moves for it).
  function styleTopics(list) {
    Object.assign(list.style, { listStyle: 'none', padding: '0', margin: '2px 0 0' });
  }
  function styleRow(row) {
    row.style.margin = '0';
    var link = row.querySelector('a');
    if (!link) return;
    var current = row.querySelector('.current') === link;
    Object.assign(link.style, {
      display: 'block', textDecoration: 'none', overflowWrap: 'anywhere',
      color: current ? 'var(--cc-fg)' : 'var(--cc-body-muted-fg)',
      background: current ? 'var(--cc-accent-soft-bg)' : 'transparent',
      boxShadow: current ? 'inset 3px 0 0 var(--cc-accent)' : 'none',
      fontWeight: current ? '600' : 'normal',
    });
    padTopic(link);
    if (!current) hoverColour(link, 'var(--cc-body-muted-fg)', 'var(--cc-accent)');
  }
  // A topic's padding: two steps in, and taller for a finger in the drawer.
  function padTopic(link) {
    link.style.padding = (narrow ? '9px ' : '4px ') + RIGHT + 'px ' + (narrow ? '9px ' : '4px ') + TOPIC_INDENT + 'px';
  }
  function hoverColour(element, resting, pointed) {
    element.addEventListener('mouseenter', function () { element.style.color = pointed; });
    element.addEventListener('mouseleave', function () { element.style.color = resting; });
  }

  // A person's choice to collapse a group or a place, kept under `key`:
  // '1' collapsed, '0' open, null none kept.
  function kept(key) {
    try { return localStorage.getItem(key); } catch (e) { return null; } // Private browsing: nothing kept.
  }
  function keep(key, collapsed) {
    try { localStorage.setItem(key, collapsed ? '1' : '0'); } catch (e) { /* Private browsing: the choice lasts this page. */ }
  }
  function startsCollapsed(section, opening) {
    if (opening === 'always') return false;
    if (opening !== 'open' && opening !== 'collapsed') throw new Error('sidebar.js: a .sidebar-place has no data-opening of always, open or collapsed');
    var choice = kept('chat-sidebar-collapsed:' + section);
    if (choice === '1') return true;
    if (choice === '0') return false;
    return opening === 'collapsed';
  }

  // A disclosure triangle for `what`, its glyph swapped and never rotated
  // (the old 9-pixel caret, turned to point right, read as a bullet),
  // showing `shown` while it is open and hiding it while collapsed, and the person's choice kept under `key`.
  // It gives `flip`, for a name that collapses too.
  function disclosure(what, shown, key, collapsed) {
    var triangle = document.createElement('span');
    triangle.setAttribute('role', 'button');
    triangle.setAttribute('tabindex', '0');
    triangle.setAttribute('aria-label', 'Collapse or open ' + what);
    // Twice the old 11 pixels, in a box TRIANGLE wide and 24 high, centred
    // on its row's text.
    Object.assign(triangle.style, {
      flex: 'none', display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      width: TRIANGLE + 'px', height: '24px', fontSize: '20px', lineHeight: '1',
      color: 'var(--cc-muted-fg)', cursor: 'pointer', userSelect: 'none', borderRadius: '4px',
    });
    function show() {
      triangle.textContent = collapsed ? '▸' : '▾';
      triangle.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
      shown.style.display = collapsed ? 'none' : 'block';
    }
    function flip() {
      collapsed = !collapsed;
      keep(key, collapsed);
      show();
    }
    show();
    onPress(triangle, flip);
    return { triangle: triangle, flip: flip };
  }
  // A click on `element`, or Enter or Space on it.
  function onPress(element, act) {
    element.addEventListener('click', act);
    element.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); act(); }
    });
  }
  // A heading's row, `level` steps in (a group's 0, a place's 1): `parts`
  // side by side, the name taking the room.
  function headingRow(before, parts, level) {
    var row = document.createElement('div');
    Object.assign(row.style, {
      display: 'flex', alignItems: 'center', gap: GAP + 'px', minHeight: '26px', margin: '0',
      padding: '0 ' + RIGHT + 'px 0 ' + (INSET + level * STEP) + 'px',
    });
    before.parentNode.insertBefore(row, before);
    parts.forEach(function (part) { row.appendChild(part); });
    return row;
  }

  // The groups: each heading's places wrapped, so the heading collapses
  // them all.
  sidebar.querySelectorAll('.sidebar-section').forEach(function (group) {
    var name = group.getAttribute('data-group');
    var heading = group.querySelector('.sidebar-section-name');
    if ((name !== 'channels' && name !== 'dms') || !heading) throw new Error('sidebar.js: a .sidebar-section has no data-group of channels or dms, or no .sidebar-section-name');
    var body = document.createElement('div');
    Array.prototype.slice.call(group.children).forEach(function (child) { if (child !== heading) body.appendChild(child); });
    group.appendChild(body);
    var key = 'chat-sidebar-group-collapsed:' + name;
    var shut = disclosure(heading.textContent, body, key, kept(key) === '1');
    headingRow(heading, [shut.triangle, heading], 0).style.marginBottom = '4px';
    heading.addEventListener('click', shut.flip);
  });

  var dots = {};
  var forms = [];
  var places = {};
  // Each DM's card, by its data-section, for the people popup.
  var cards = {};
  sidebar.querySelectorAll('.sidebar-place').forEach(function (place) {
    var section = place.getAttribute('data-section');
    var name = place.querySelector('.sidebar-place-name');
    var list = place.querySelector('.sidebar-topics');
    var form = place.querySelector('form');
    var plus = place.querySelector('.sidebar-new-topic');
    var group = place.closest('.sidebar-section');
    if (!section || !name || !list || !form || !plus || !group) throw new Error('sidebar.js: a .sidebar-place has no data-section, .sidebar-place-name, .sidebar-topics, form or .sidebar-new-topic, or is in no .sidebar-section');
    places[section] = list;
    styleTopics(list);
    list.querySelectorAll('li').forEach(styleRow);
    var label = name.textContent;

    var person = place.getAttribute('data-person');
    if (person) {
      var dot = document.createElement('span');
      SidebarPopups.paintDot(dot, place.getAttribute('data-presence') === 'online');
      dots[person] = { dot: dot, place: place };
      name.insertBefore(dot, name.firstChild);
    }
    name.setAttribute('role', 'button');
    name.setAttribute('tabindex', '0');

    var words = plus.textContent;
    plus.type = 'button';
    plus.textContent = '+';
    plus.title = words;
    plus.setAttribute('aria-label', words);
    hoverColour(plus, 'var(--cc-muted-fg)', 'var(--cc-accent)');
    form.remove();
    forms.push(form);
    var popup = SidebarPopups.topicPopup(form, words, plus);
    plus.addEventListener('click', popup.open);

    var shut = disclosure(label, list, 'chat-sidebar-collapsed:' + section, startsCollapsed(section, place.getAttribute('data-opening')));
    headingRow(name, [shut.triangle, name, plus], 1);
    if (group.getAttribute('data-group') === 'dms') {
      name.title = 'About ' + label;
      hoverColour(name, 'var(--cc-meta-fg)', 'var(--cc-accent)');
      var card = SidebarPopups.personPopup(place, label, list, name, popup);
      cards[section] = card;
      onPress(name, card.open);
    } else {
      onPress(name, shut.flip);
    }
  });

  // The DMs that wait (app/DmShortlist.roc): kept out of sight, and the
  // row before them, "N more people…", a place's name's indent in from the
  // group, muted, opens the people popup that lists them. It has no
  // triangle, since it never opens in place, and it collapses with its
  // group.
  sidebar.querySelectorAll('.sidebar-more').forEach(function (more) {
    var row = more.querySelector('.sidebar-more-name');
    if (!row) throw new Error('sidebar.js: a .sidebar-more has no .sidebar-more-name');
    var people = [];
    more.querySelectorAll('.sidebar-place').forEach(function (place) {
      var section = place.getAttribute('data-section');
      people.push({ label: place.querySelector('.sidebar-place-name').textContent, place: place, card: cards[section] });
      place.style.display = 'none';
    });
    row.setAttribute('role', 'button');
    row.setAttribute('tabindex', '0');
    Object.assign(row.style, {
      margin: '0', minHeight: '26px', display: 'flex', alignItems: 'center', cursor: 'pointer', userSelect: 'none',
      padding: '0 ' + RIGHT + 'px 0 ' + (INSET + STEP + TRIANGLE + GAP) + 'px',
      color: 'var(--cc-muted-fg)', fontSize: '12px',
    });
    hoverColour(row, 'var(--cc-muted-fg)', 'var(--cc-accent)');
    onPress(row, SidebarPopups.peoplePopup(people, row).open);
  });

  // The drawer, chat-client's: the sidebar fixed at the window's left edge,
  // off the screen until it opens, over a backdrop.
  var label = toggle.textContent;
  toggle.type = 'button';
  toggle.textContent = '☰';
  toggle.title = label;
  toggle.setAttribute('aria-label', label);
  Object.assign(toggle.style, {
    background: 'none', border: 'none', cursor: 'pointer', fontSize: '22px', lineHeight: '1',
    padding: '0 4px', color: 'var(--cc-accent)', flex: 'none',
  });
  topBar.insertBefore(toggle, topBar.firstChild);
  var backdrop = document.createElement('div');
  Object.assign(backdrop.style, {
    display: 'none', position: 'fixed', inset: '0', zIndex: '99', background: 'rgba(0, 0, 0, 0.4)',
  });
  document.body.appendChild(backdrop);

  // The rail is a box as the message list is: a 1-pixel border in the
  // palette's border colour, 8-pixel corners, its rows' own padding its
  // indent. The drawer keeps a border at its right edge alone.
  var railStyle = {
    position: '', top: '', left: '', bottom: '', zIndex: '', width: '224px', flex: 'none', padding: '10px 0',
    border: '1px solid var(--cc-border)', borderRadius: '8px',
    background: '', transform: '', transition: '', visibility: '', fontSize: '13px',
  };
  var drawerStyle = {
    position: 'fixed', top: '0', left: '0', bottom: '0', zIndex: '100', width: 'min(280px, 85vw)', padding: '14px 0',
    border: 'none', borderRight: '1px solid var(--cc-border)', borderRadius: '0',
    background: 'var(--cc-bg)', transition: '', fontSize: '15px',
  };
  // The layout's room at the left, 24 pixels for every page, is 12 beside
  // the rail, so the rail sits near the window's edge; the drawer leaves
  // the layout as chrome.js has it.
  var layout = sidebar.parentNode;
  var slide = 'transform 0.25s ease, visibility 0.25s';
  var open = false;
  function show(opened) {
    open = opened && narrow;
    toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    backdrop.style.display = open ? 'block' : 'none';
    if (!narrow) return;
    sidebar.style.transform = open ? 'none' : 'translateX(-100%)';
    sidebar.style.visibility = open ? 'visible' : 'hidden';
    if (open) (sidebar.querySelector('.current') || sidebar).focus();
  }
  sidebar.tabIndex = -1;
  // A finger's targets in the drawer, a mouse's on the rail.
  function sizeTargets() {
    sidebar.querySelectorAll('.sidebar-topics a').forEach(padTopic);
    styleAll('.sidebar-place-name', { padding: narrow ? '6px 0' : '0' });
    styleAll('.sidebar-section-name', { padding: narrow ? '6px 0' : '0' });
    styleAll('.sidebar-more-name', { minHeight: narrow ? '38px' : '26px' });
    styleAll('[aria-expanded]', { padding: narrow ? '6px 0' : '0' });
    styleAll('.sidebar-new-topic', { padding: narrow ? '8px 12px' : '2px 6px' });
    forms.forEach(function (form) {
      form.querySelectorAll('button').forEach(function (button) { button.style.padding = narrow ? '6px 14px' : '2px 10px'; });
    });
  }
  Viewport.onChange(function (isNarrow) {
    narrow = isNarrow;
    toggle.style.display = narrow ? 'inline-block' : 'none';
    Object.assign(sidebar.style, narrow ? drawerStyle : railStyle);
    layout.style.paddingLeft = narrow ? '' : '12px';
    sizeTargets();
    show(false);
  });
  // It slides once it is laid out, so a narrow page doesn't open with a
  // slide.
  toggle.addEventListener('click', function () {
    sidebar.style.transition = narrow ? slide : '';
    show(!open);
  });
  backdrop.addEventListener('click', function () { show(false); });
  document.addEventListener('keydown', function (e) {
    if (open && !SidebarPopups.isOpen() && e.key === 'Escape') { e.preventDefault(); show(false); toggle.focus(); }
  });
  sidebar.addEventListener('click', function (e) {
    if (e.target.closest && e.target.closest('.sidebar-topics a')) show(false);
  });

  // A topic added to the place `section`, as the server writes a row, first
  // among the place's topics, its newest; a topic already there is left.
  function addTopic(section, label, url) {
    var list = places[section];
    if (!list) return;
    var rows = Array.prototype.slice.call(list.querySelectorAll('li'));
    if (rows.some(function (row) { var link = row.querySelector('a'); return link && link.textContent === label; })) return;
    var row = document.createElement('li');
    var link = document.createElement('a');
    link.href = url;
    link.textContent = label;
    row.appendChild(link);
    styleRow(row);
    list.insertBefore(row, list.firstChild);
  }

  // A human come online: their DM's dot filled.
  function markOnline(person) {
    var shown = dots[person];
    if (!shown) return;
    shown.place.setAttribute('data-presence', 'online');
    SidebarPopups.paintDot(shown.dot, true);
  }

  // A `topic-added` event's data: the place's path, the topic and its page.
  function topicAdded(data) {
    var fields = data.split('\n');
    if (fields.length !== 3) throw new Error('sidebar.js: a topic-added event is three lines, the place, the topic and its page');
    addTopic(fields[0], fields[1], fields[2]);
  }

  return { addTopic: addTopic, topicAdded: topicAdded, markOnline: markOnline };
})();
