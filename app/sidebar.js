// This script runs on a conversation page that has a sidebar, which
// app/Sidebar.roc builds and app/Script.roc serves. The server writes the
// sidebar whole, in app/SidebarOrder.roc's order: the page's own place
// first, then the others newest first, each place's topics under it as
// links, newest first, the current topic marked, and the form that starts a
// topic at the end of each place. This script gives it chat-client's
// behaviour (js/chat_left_sidebar.js), without that rail's pinning or
// dragging. It never moves a place: the order is the server's, as the page
// was drawn.
//
// Its look is Steve's, not chat-client's: like a good referee, it should
// feel invisible until you need it. Only the page's own place (data-opening
// `always`) is bold, the current topic is marked by a thin line at its left,
// the rows sit close, and a link pointed at shows by its text's colour, never
// a fill.
//
// Presence, chat-client's: a DM with another human (data-person) has a dot
// before its name, a hollow ring while they are away and solid green while
// they are online (data-presence). The page's stream (feed.js) passes on
// `online` from the viewer's own key, a human's id, which fills their dot
// (Sidebar.markOnline). A dot never empties while the page is open: as in
// chat-client, the next page drawn says who is still online. The notices
// above the page, and the tab's violet icon, are chrome.js's (Notices).
//
// In a window wider than 768 pixels the sidebar is a rail 180 pixels wide on
// the left of the layout. Clicking a place's name, or Enter or Space on it,
// collapses or opens its topics and its form, as chat-client's sections do.
// Each place starts as the server says (data-opening): `open`, `collapsed`,
// or `always`, the page's own place, which opens on every load. Once a
// person opens or collapses a place, their choice is kept across reloads
// (localStorage, by the place's data-section) and wins over `open` and
// `collapsed`.
//
// In a narrow window (chrome.js's Viewport) the sidebar is a drawer, as
// chat-client's was (js/chrome_drawer.js and js/chat_responsive.js): the
// server's toggle button moves to the start of the top bar as a ☰, and a tap
// slides the sidebar in from the left over the page, a backdrop dimming the
// rest. A tap on the backdrop, Escape, the ☰ again, or choosing a topic
// closes it, and so does widening the window. Its links and buttons are
// larger, for a finger.
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
// its label. The "+" opens a popup, a modal dialog as feed.js's code popup
// is, holding the form, its field focused: Enter adds the topic, and Escape
// or Close cancels. The form posts as it always has, to the place's path: a
// topic the server takes answers with its page, which the browser then
// opens; one it refuses answers with Browse, whose problem paragraph
// (.problem) the popup shows, keeping what was typed.
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

  function styleAll(selector, style) {
    sidebar.querySelectorAll(selector).forEach(function (element) { Object.assign(element.style, style); });
  }

  Object.assign(sidebar.style, { overflowY: 'auto', borderRight: '1px solid var(--cc-border)', boxSizing: 'border-box' });
  styleAll('.sidebar-place', { marginBottom: '6px' });
  styleAll('.sidebar-place-name', {
    display: 'flex', alignItems: 'center', gap: '5px', margin: '0', flex: '1', minWidth: '0', fontWeight: 'normal',
    color: 'var(--cc-meta-fg)', cursor: 'pointer', userSelect: 'none',
  });
  // The page's own place, alone bold.
  styleAll('.sidebar-place[data-opening="always"] .sidebar-place-name', { fontWeight: 'bold' });
  // The "+": light until pointed at, and a finger's size in the drawer.
  styleAll('.sidebar-new-topic', {
    flex: 'none', background: 'none', border: 'none', borderRadius: '4px', cursor: 'pointer',
    color: 'var(--cc-muted-fg)', fontSize: '15px', lineHeight: '1', fontFamily: 'inherit',
  });
  var backdropRule = document.createElement('style');
  backdropRule.textContent = 'dialog.topic-popup::backdrop { background: var(--cc-backdrop); }';
  document.head.appendChild(backdropRule);
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

  // A list of topics, and each row in it: the current topic marked by a
  // thin line at its left, which every row leaves room for so the names
  // line up, and a topic pointed at shown by its text's colour.
  function styleTopics(list) {
    Object.assign(list.style, { listStyle: 'none', padding: '0', margin: '0' });
  }
  function styleRow(row) {
    row.style.margin = '0';
    var link = row.querySelector('a');
    if (!link) return;
    var current = row.querySelector('.current') === link;
    Object.assign(link.style, {
      display: 'block', padding: '2px 8px', textDecoration: 'none', overflowWrap: 'anywhere',
      color: 'var(--cc-accent)', background: 'transparent', fontWeight: 'normal',
      borderLeft: '2px solid ' + (current ? 'var(--cc-accent)' : 'transparent'),
    });
    if (!current) {
      link.addEventListener('mouseenter', function () { link.style.color = 'var(--cc-fg)'; });
      link.addEventListener('mouseleave', function () { link.style.color = 'var(--cc-accent)'; });
    }
  }

  // Collapsing, chat-client's: a caret that points down while the place is
  // open and right while it is collapsed. A person's choice is kept per
  // place, '1' collapsed and '0' open; with none kept, the server's
  // data-opening decides.
  function collapseKey(section) { return 'chat-sidebar-collapsed:' + section; }
  function startsCollapsed(section, opening) {
    if (opening === 'always') return false;
    if (opening !== 'open' && opening !== 'collapsed') throw new Error('sidebar.js: a .sidebar-place has no data-opening of always, open or collapsed');
    var kept = null;
    try { kept = localStorage.getItem(collapseKey(section)); } catch (e) { /* Private browsing: nothing kept. */ }
    if (kept === '1') return true;
    if (kept === '0') return false;
    return opening === 'collapsed';
  }
  function storeCollapsed(section, collapsed) {
    try { localStorage.setItem(collapseKey(section), collapsed ? '1' : '0'); } catch (e) { /* Private browsing: the choice lasts this page. */ }
  }

  // A DM's dot: chat-client's hollow ring, filled while the person is online.
  var dots = {};
  function paintDot(dot, online) {
    Object.assign(dot.style, {
      display: 'inline-block', width: '9px', height: '9px', borderRadius: '50%', boxSizing: 'border-box',
      flex: 'none', border: '1.5px solid ' + (online ? 'var(--cc-presence-online)' : 'var(--cc-presence-idle)'),
      background: online ? 'var(--cc-presence-online)' : 'transparent',
    });
    dot.title = online ? 'online' : 'away';
  }

  // A place's new-topic popup, `form` in a modal dialog headed `words`, made
  // afresh at each opening and removed once closed, giving the focus back
  // to `plus`. The form is posted by fetch, so a refusal stays in the popup.
  var forms = [];
  var popupOpen = false;
  function topicPopup(form, words, plus) {
    forms.push(form);
    var input = form.querySelector('input');
    var submit = form.querySelector('button');
    if (!input || !submit) throw new Error('sidebar.js: a new-topic form has no input or button');
    var problem = document.createElement('p');
    Object.assign(problem.style, { margin: '8px 0 0', fontSize: '13px', color: 'var(--cc-notify-fg)' });
    var dlg = null;
    function say(text) {
      problem.textContent = text;
      submit.disabled = false;
      input.focus();
    }
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      submit.disabled = true;
      problem.textContent = '';
      fetch(form.action, { method: 'POST', body: new URLSearchParams(new FormData(form)), credentials: 'same-origin' })
        .then(function (answer) {
          if (answer.ok && answer.redirected) { window.location.assign(answer.url); return; }
          return answer.text().then(function (html) {
            var said = new DOMParser().parseFromString(html, 'text/html').querySelector('.problem');
            say(said ? said.textContent : 'The server answered ' + answer.status + ' and said nothing more.');
          });
        }, function () { say('The server did not answer; try again.'); });
    });
    function open() {
      dlg = document.createElement('dialog');
      dlg.className = 'topic-popup';
      Object.assign(dlg.style, {
        width: 'min(320px, 90vw)', padding: '0', border: '1px solid var(--cc-dialog-border)', borderRadius: '8px',
        background: 'var(--cc-bg)', color: 'var(--cc-fg)',
      });
      var controls = document.createElement('div');
      Object.assign(controls.style, {
        display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '8px',
        padding: '6px 8px', borderBottom: '1px solid var(--cc-soft-border)', background: 'var(--cc-code-strap-bg)',
      });
      var heading = document.createElement('span');
      heading.textContent = words;
      Object.assign(heading.style, { fontWeight: 'bold', fontSize: '13px', overflowWrap: 'anywhere' });
      var close = document.createElement('button');
      close.type = 'button';
      close.textContent = 'Close';
      close.addEventListener('click', function () { dlg.close(); });
      controls.appendChild(heading);
      controls.appendChild(close);
      var body = document.createElement('div');
      body.style.padding = '12px 14px';
      Object.assign(form.style, { margin: '0' });
      body.appendChild(form);
      body.appendChild(problem);
      dlg.appendChild(controls);
      dlg.appendChild(body);
      dlg.addEventListener('close', function () {
        popupOpen = false;
        problem.textContent = '';
        submit.disabled = false;
        dlg.remove();
        plus.focus();
      });
      dlg.addEventListener('click', function (e) { if (e.target === dlg) dlg.close(); });
      document.body.appendChild(dlg);
      popupOpen = true;
      dlg.showModal();
      input.focus();
      input.select();
    }
    return { open: open };
  }

  var places = {};
  sidebar.querySelectorAll('.sidebar-place').forEach(function (place) {
    var section = place.getAttribute('data-section');
    var name = place.querySelector('.sidebar-place-name');
    var list = place.querySelector('.sidebar-topics');
    var form = place.querySelector('form');
    var plus = place.querySelector('.sidebar-new-topic');
    if (!section || !name || !list || !form || !plus) throw new Error('sidebar.js: a .sidebar-place has no data-section, .sidebar-place-name, .sidebar-topics, form or .sidebar-new-topic');
    places[section] = list;
    styleTopics(list);
    list.querySelectorAll('li').forEach(styleRow);

    var caret = document.createElement('span');
    caret.textContent = '▾';
    Object.assign(caret.style, { display: 'inline-block', fontSize: '9px', transition: 'transform 0.15s ease' });
    var person = place.getAttribute('data-person');
    if (person) {
      var dot = document.createElement('span');
      paintDot(dot, place.getAttribute('data-presence') === 'online');
      dots[person] = { dot: dot, place: place };
      name.insertBefore(dot, name.firstChild);
    }
    name.insertBefore(caret, name.firstChild);
    name.setAttribute('role', 'button');
    name.setAttribute('tabindex', '0');

    var row = document.createElement('div');
    Object.assign(row.style, { display: 'flex', alignItems: 'center', gap: '4px', margin: '0 0 2px' });
    place.insertBefore(row, name);
    row.appendChild(name);
    row.appendChild(plus);
    var words = plus.textContent;
    plus.type = 'button';
    plus.textContent = '+';
    plus.title = words;
    plus.setAttribute('aria-label', words);
    plus.addEventListener('mouseenter', function () { plus.style.color = 'var(--cc-accent)'; });
    plus.addEventListener('mouseleave', function () { plus.style.color = 'var(--cc-muted-fg)'; });
    form.remove();
    var popup = topicPopup(form, words, plus);
    plus.addEventListener('click', popup.open);

    function show(collapsed) {
      caret.style.transform = collapsed ? 'rotate(-90deg)' : 'none';
      list.style.display = collapsed ? 'none' : 'block';
      name.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
    }
    var collapsed = startsCollapsed(section, place.getAttribute('data-opening'));
    show(collapsed);
    function flip() {
      collapsed = !collapsed;
      storeCollapsed(section, collapsed);
      show(collapsed);
    }
    name.addEventListener('click', flip);
    name.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); flip(); }
    });
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

  var railStyle = {
    position: '', top: '', left: '', bottom: '', zIndex: '', width: '180px', flex: 'none', padding: '0 14px 0 0',
    background: '', transform: '', transition: '', visibility: '', fontSize: '13px',
  };
  var drawerStyle = {
    position: 'fixed', top: '0', left: '0', bottom: '0', zIndex: '100', width: 'min(280px, 85vw)', padding: '14px',
    background: 'var(--cc-bg)', transition: '', fontSize: '15px',
  };
  var slide = 'transform 0.25s ease, visibility 0.25s';
  var narrow = false;
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
    styleAll('.sidebar-topics a', { padding: narrow ? '9px 8px' : '2px 8px' });
    styleAll('.sidebar-place-name', { padding: narrow ? '6px 0' : '0' });
    styleAll('.sidebar-new-topic', { padding: narrow ? '8px 12px' : '2px 6px' });
    forms.forEach(function (form) {
      form.querySelectorAll('button').forEach(function (button) { button.style.padding = narrow ? '6px 14px' : '2px 10px'; });
    });
  }
  Viewport.onChange(function (isNarrow) {
    narrow = isNarrow;
    toggle.style.display = narrow ? 'inline-block' : 'none';
    Object.assign(sidebar.style, narrow ? drawerStyle : railStyle);
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
    if (open && !popupOpen && e.key === 'Escape') { e.preventDefault(); show(false); toggle.focus(); }
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
    link.style.padding = narrow ? '9px 8px' : '2px 8px';
    list.insertBefore(row, list.firstChild);
  }

  // A human come online: their DM's dot filled.
  function markOnline(person) {
    var shown = dots[person];
    if (!shown) return;
    shown.place.setAttribute('data-presence', 'online');
    paintDot(shown.dot, true);
  }

  // A `topic-added` event's data: the place's path, the topic and its page.
  function topicAdded(data) {
    var fields = data.split('\n');
    if (fields.length !== 3) throw new Error('sidebar.js: a topic-added event is three lines, the place, the topic and its page');
    addTopic(fields[0], fields[1], fields[2]);
  }

  return { addTopic: addTopic, topicAdded: topicAdded, markOnline: markOnline };
})();
