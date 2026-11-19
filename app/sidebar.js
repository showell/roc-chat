// This script runs on a conversation page that has a sidebar, which
// app/Sidebar.roc builds and app/Script.roc serves. The server writes the
// sidebar whole: the viewer's DMs, then their channels, each place's topics
// under it as links, the current topic marked, and the form that starts a
// topic at the end of each place. This script gives it chat-client's look and
// behaviour (js/chat_left_sidebar.js), without that rail's pinning, dragging
// or presence.
//
// In a window wider than 768 pixels the sidebar is a rail 180 pixels wide on
// the left of the layout. Clicking a place's name, or Enter or Space on it,
// collapses or opens its topics and its form, as chat-client's sections do,
// and a collapsed place stays collapsed across reloads (localStorage, by the
// place's data-section).
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
// data-section is `section`, built as the server's rows are; the stream that
// tells a page of a new topic will call it.
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
  styleAll('.sidebar-heading', {
    fontSize: '11px', textTransform: 'uppercase', letterSpacing: '0.05em', color: 'var(--cc-muted-fg)',
    fontWeight: 'bold', margin: '0 0 6px',
  });
  styleAll('.sidebar-place', { marginBottom: '12px' });
  styleAll('.sidebar-place-name', {
    display: 'flex', alignItems: 'center', gap: '5px', margin: '0 0 4px', fontWeight: 'bold',
    color: 'var(--cc-meta-fg)', cursor: 'pointer', userSelect: 'none',
  });
  styleAll('form', { margin: '4px 0 0', display: 'flex', flexDirection: 'column', gap: '4px' });
  styleAll('form p', { margin: '0', fontSize: '12px', color: 'var(--cc-muted-fg)' });
  styleAll('input', {
    boxSizing: 'border-box', width: '100%', fontFamily: 'inherit', fontSize: '12px', padding: '2px 6px',
    background: 'var(--cc-bg)', color: 'var(--cc-fg)', border: '1px solid var(--cc-input-border)', borderRadius: '4px',
  });
  styleAll('button', {
    alignSelf: 'flex-start', fontSize: '12px', padding: '2px 10px', background: 'var(--cc-mine-bg)',
    color: 'var(--cc-search-tok-fg)', border: '1px solid var(--cc-quote-border)', borderRadius: '6px', cursor: 'pointer',
  });

  // A list of topics, and each row in it, as chat-client styles them.
  function styleTopics(list) {
    Object.assign(list.style, { listStyle: 'none', padding: '0', margin: '0' });
  }
  function styleRow(row) {
    row.style.margin = '0';
    if (row.classList.contains('sidebar-empty')) {
      Object.assign(row.style, { color: 'var(--cc-muted-fg)', padding: '4px 8px', fontStyle: 'italic' });
      return;
    }
    var link = row.querySelector('a');
    if (!link) return;
    var current = row.querySelector('.current') === link;
    Object.assign(link.style, {
      display: 'block', padding: '4px 8px', borderRadius: '3px', textDecoration: 'none',
      overflowWrap: 'anywhere', color: current ? 'var(--cc-bg)' : 'var(--cc-accent)',
      background: current ? 'var(--cc-accent)' : 'transparent', fontWeight: current ? 'bold' : 'normal',
    });
    if (!current) {
      link.addEventListener('mouseenter', function () { link.style.background = 'var(--cc-accent-soft-bg)'; });
      link.addEventListener('mouseleave', function () { link.style.background = 'transparent'; });
    }
  }

  // Collapsing, chat-client's: a caret that points down while the place is
  // open and right while it is collapsed, kept per place.
  function collapseKey(section) { return 'chat-sidebar-collapsed:' + section; }
  function isCollapsed(section) {
    try { return localStorage.getItem(collapseKey(section)) === '1'; } catch (e) { return false; } // Private browsing: nothing kept.
  }
  function storeCollapsed(section, collapsed) {
    try {
      if (collapsed) localStorage.setItem(collapseKey(section), '1');
      else localStorage.removeItem(collapseKey(section));
    } catch (e) { /* Private browsing: the choice lasts this page. */ }
  }

  var places = {};
  sidebar.querySelectorAll('.sidebar-place').forEach(function (place) {
    var section = place.getAttribute('data-section');
    var name = place.querySelector('.sidebar-place-name');
    var list = place.querySelector('.sidebar-topics');
    var form = place.querySelector('form');
    if (!section || !name || !list) throw new Error('sidebar.js: a .sidebar-place has no data-section, .sidebar-place-name or .sidebar-topics');
    places[section] = list;
    styleTopics(list);
    list.querySelectorAll('li').forEach(styleRow);

    var caret = document.createElement('span');
    caret.textContent = '▾';
    Object.assign(caret.style, { display: 'inline-block', fontSize: '9px', transition: 'transform 0.15s ease' });
    name.insertBefore(caret, name.firstChild);
    name.setAttribute('role', 'button');
    name.setAttribute('tabindex', '0');

    function show(collapsed) {
      caret.style.transform = collapsed ? 'rotate(-90deg)' : 'none';
      list.style.display = collapsed ? 'none' : 'block';
      if (form) form.style.display = collapsed ? 'none' : 'flex';
      name.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
    }
    var collapsed = isCollapsed(section);
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
    styleAll('.sidebar-topics a, .sidebar-empty', { padding: narrow ? '9px 8px' : '4px 8px' });
    styleAll('.sidebar-place-name', { padding: narrow ? '6px 0' : '0' });
    styleAll('button', { padding: narrow ? '6px 14px' : '2px 10px' });
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
    if (open && e.key === 'Escape') { e.preventDefault(); show(false); toggle.focus(); }
  });
  sidebar.addEventListener('click', function (e) {
    if (e.target.closest && e.target.closest('.sidebar-topics a')) show(false);
  });

  // A topic added to the place `section`, as the server writes a row, in
  // byte order among the place's topics; a topic already there is left.
  function addTopic(section, label, url) {
    var list = places[section];
    if (!list) return;
    var rows = Array.prototype.slice.call(list.querySelectorAll('li'));
    if (rows.some(function (row) { var link = row.querySelector('a'); return link && link.textContent === label; })) return;
    var empty = list.querySelector('.sidebar-empty');
    if (empty) empty.remove();
    var row = document.createElement('li');
    var link = document.createElement('a');
    link.href = url;
    link.textContent = label;
    row.appendChild(link);
    styleRow(row);
    link.style.padding = narrow ? '9px 8px' : '4px 8px';
    var after = rows.filter(function (other) { var a = other.querySelector('a'); return a && a.textContent > label; })[0];
    list.insertBefore(row, after || null);
  }

  return { addTopic: addTopic };
})();
