// This script runs on a conversation page that has a sidebar, before
// app/sidebar.js, which opens its popups. app/Script.roc serves it. Each
// popup is a modal dialog over a dimmed page, as feed.js's code popup is: a
// strap at its top with its heading and a Close button, made afresh at each
// opening and removed once closed, the focus going back to what opened it.
// Escape, Close, or a click outside it closes it. A dialog sits above the
// phone's drawer, so each works there too.
//
// A place has one popup, its card, opened two ways (Steve, 2026-11-20:
// "popups can be roomy and convenient... if you click the + icon, the popup
// should still show existing topics beneath the UX for adding the new
// topic. This trains the user that they're allowed to explore the app").
// The "+" (or the n key, for the page's own place) opens it with the
// place's new-topic form on top and its topics under it; the place's name
// opens it with the place first: a DM's person, whether they are online now
// (the place's data-presence, which sidebar.js keeps up to date) and when
// they joined when the server says (data-joined, seconds since 1970, shown
// as a date in the viewer's own time), or a channel's name; then its
// topics, then the form. A DM's card and a channel's are one card (Steve,
// 2026-11-20: "channels UX features mostly match DM UX"). Either way the
// focus starts in the form's field: Enter adds the topic, ↓ and ↑ move
// through the topics' links, Enter on one opens it, and Escape or Close
// closes the card. The form posts as it always has, to the place's path,
// but by fetch: a topic the server takes answers with its page, which the
// browser then opens; one it refuses answers with Browse, whose problem
// paragraph (.problem) the card shows under the form, keeping what was
// typed. A popup is roomy, so its action is in it, and no popup opens
// another.
//
// The people popup lists the DMs the sidebar keeps out of sight, behind
// the DMs group's "more" row, with a filter field; choosing one shows their
// card in the same popup.
//
// SidebarPopups.paintDot is the presence dot, chat-client's: a hollow ring
// while the person is away, solid green while they are online. Its colours
// are palette.js's.
window.SidebarPopups = (function () {
  'use strict';
  // What can't be inlined: the backdrop, and the buttons' and links' hover
  // and keyboard focus. The buttons are compose.js's family: the primary
  // action in the accent, the rest quiet, 13 pixels, 6-pixel corners.
  var rules = document.createElement('style');
  rules.textContent = [
    'dialog.sidebar-popup::backdrop{background:var(--cc-backdrop)}',
    '.sidebar-popup button{font-family:inherit;font-size:13px;padding:5px 14px;border-radius:6px;cursor:pointer}',
    '.sidebar-popup .popup-primary{align-self:flex-start;background:var(--cc-accent);color:var(--cc-bg);border:1px solid var(--cc-accent)}',
    '.sidebar-popup .popup-primary:hover:not(:disabled){background:var(--cc-accent-hover);border-color:var(--cc-accent-hover)}',
    '.sidebar-popup .popup-primary:disabled{opacity:.5;cursor:default}',
    '.sidebar-popup .popup-secondary{background:none;color:var(--cc-fg);border:1px solid var(--cc-quote-border)}',
    '.sidebar-popup .popup-secondary:hover{background:var(--cc-accent-soft-hov)}',
    '.sidebar-popup button:focus-visible,.sidebar-popup a:focus-visible,.sidebar-popup [role=button]:focus-visible' +
      '{outline:2px solid var(--cc-accent);outline-offset:2px}',
    '.sidebar-popup .popup-topic{display:block;padding:5px 8px;border-radius:6px;font-size:14px;' +
      'color:var(--cc-accent);text-decoration:none;overflow-wrap:anywhere}',
    '.sidebar-popup .popup-topic:hover,.sidebar-popup .popup-topic:focus-visible{background:var(--cc-accent-soft-bg)}',
    '.sidebar-popup .popup-topic[aria-current]{color:var(--cc-fg);font-weight:600}',
  ].join('\n');
  document.head.appendChild(rules);

  // How many popups are open: sidebar.js leaves Escape to an open one.
  var opened = 0;
  function isOpen() { return opened > 0; }

  function paintDot(dot, online) {
    Object.assign(dot.style, {
      display: 'inline-block', width: '9px', height: '9px', borderRadius: '50%', boxSizing: 'border-box',
      flex: 'none', border: '1.5px solid ' + (online ? 'var(--cc-presence-online)' : 'var(--cc-presence-idle)'),
      background: online ? 'var(--cc-presence-online)' : 'transparent',
    });
    dot.title = online ? 'online' : 'away';
  }

  // A popup's frame: a dialog 380 pixels wide (capped to a phone's
  // window), its strap headed `words`, and its body roomy, padded 18 by 20.
  // `show` opens it; once closed it is removed and the focus goes back to
  // `opener`.
  function frame(className, words, opener) {
    var dlg = document.createElement('dialog');
    dlg.className = className + ' sidebar-popup';
    Object.assign(dlg.style, {
      width: 'min(380px, 92vw)', boxSizing: 'border-box', padding: '0', border: '1px solid var(--cc-dialog-border)',
      borderRadius: '10px', background: 'var(--cc-bg)', color: 'var(--cc-fg)', lineHeight: '1.45',
    });
    var controls = document.createElement('div');
    Object.assign(controls.style, {
      display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '8px',
      padding: '8px 10px 8px 20px', borderBottom: '1px solid var(--cc-soft-border)', background: 'var(--cc-code-strap-bg)',
    });
    var heading = document.createElement('span');
    heading.textContent = words;
    Object.assign(heading.style, { fontWeight: 'bold', fontSize: '13px', overflowWrap: 'anywhere' });
    var close = document.createElement('button');
    close.type = 'button';
    close.textContent = 'Close';
    close.className = 'popup-secondary';
    close.addEventListener('click', function () { dlg.close(); });
    controls.appendChild(heading);
    controls.appendChild(close);
    var body = document.createElement('div');
    body.style.padding = '18px 20px 20px';
    dlg.appendChild(controls);
    dlg.appendChild(body);
    dlg.addEventListener('close', function () {
      opened -= 1;
      dlg.remove();
      opener.focus();
    });
    dlg.addEventListener('click', function (e) { if (e.target === dlg) dlg.close(); });
    function show() {
      document.body.appendChild(dlg);
      opened += 1;
      dlg.showModal();
    }
    return { heading: heading, body: body, show: show, close: function () { dlg.close(); } };
  }

  // A place's new-topic popup, `form` headed `words`, giving the focus back  // A place's new-topic form, moved into whichever popup shows it. It is
  // posted by fetch, so a refusal stays in the popup. Its field and its
  // button are restyled for a popup: the field roomy, the button the
  // house's primary one (as compose.js's Send).
  function topicForm(form) {
    var input = form.querySelector('input');
    var submit = form.querySelector('button');
    if (!input || !submit) throw new Error('sidebar-popups.js: a new-topic form has no input or button');
    submit.removeAttribute('style');
    submit.className = 'popup-primary';
    Object.assign(input.style, { fontSize: '14px', padding: '6px 8px', borderRadius: '6px', marginTop: '4px' });
    Object.assign(form.style, { gap: '8px' });
    var problem = document.createElement('p');
    Object.assign(problem.style, { margin: '8px 0 0', fontSize: '13px', color: 'var(--cc-notify-fg)' });
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
    // The form, and the line that says a refusal, put fresh into `into`.
    // One popup is open at a time, so the one form moves to whichever
    // holds it.
    function mount(into) {
      problem.textContent = '';
      submit.disabled = false;
      form.style.margin = '0';
      into.appendChild(form);
      into.appendChild(problem);
    }
    return { mount: mount, input: input };
  }

  // A small muted line of a place card.
  function cardLine(text) {
    var line = document.createElement('p');
    line.textContent = text;
    Object.assign(line.style, { margin: '0 0 6px', fontSize: '13px', color: 'var(--cc-meta-fg)' });
    return line;
  }
  function joinedWords(seconds) {
    if (!/^[0-9]+$/.test(seconds)) throw new Error('sidebar-popups.js: a data-joined is seconds since 1970, digits');
    var day = new Date(Number(seconds) * 1000);
    return 'Joined ' + day.toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' });
  }
  // A small capitalised heading of a card's part.
  function cardHeading(text, top) {
    var heading = cardLine(text);
    Object.assign(heading.style, {
      margin: top + ' 0 6px', fontSize: '11px', fontWeight: '600', letterSpacing: '0.06em',
      textTransform: 'uppercase', color: 'var(--cc-muted-fg)',
    });
    return heading;
  }

  // The place's topics `list` (the sidebar's, newest first) as a column of
  // links, one a row, each opening its topic; none says so.
  function topicLinks(list) {
    var links = list.querySelectorAll('li a');
    if (links.length === 0) {
      var none = cardLine('No topics yet.');
      none.style.color = 'var(--cc-muted-fg)';
      return none;
    }
    var column = document.createElement('div');
    Object.assign(column.style, { display: 'flex', flexDirection: 'column', maxHeight: '40vh', overflowY: 'auto', margin: '0 -8px' });
    links.forEach(function (shown) {
      var link = document.createElement('a');
      link.href = shown.getAttribute('href');
      link.textContent = shown.textContent;
      link.className = 'popup-topic';
      if (shown.classList.contains('current')) link.setAttribute('aria-current', 'page');
      column.appendChild(link);
    });
    return column;
  }

  // The card of `place`, a DM or a channel, named `who`, its topics `list`
  // and its new-topic form `topic` (a topicForm). One card, opened two ways,
  // with the focus in the form's field either way, Enter adding the topic:
  // `open('new', plus)`, by the "+", has the form on top and the place's
  // topics under it, so the popup also shows where one can go next;
  // `open('about', name)`, by the place's name, says the place's name and,
  // for a DM, its person's presence and when they joined, then the topics,
  // then the form. A popup is roomy, so its action is right in it, never
  // behind a second popup (Steve, 2026-11-20). ↓ and ↑ move from the field
  // through the topics' links, Enter opens one, and the focus goes back to
  // what opened the card when it closes. `fill(body, mode)` writes the card
  // into another popup's body, the people popup's.
  function placePopup(place, who, list, topic) {
    function open(mode, opener) {
      var popup = frame('place-popup', mode === 'new' ? 'New topic in ' + who : '', opener);
      fill(popup.body, mode);
      popup.show();
      topic.input.focus();
      topic.input.select();
    }
    function about(body) {
      var title = document.createElement('p');
      title.textContent = who;
      Object.assign(title.style, { margin: '0 0 8px', fontSize: '17px', fontWeight: 'bold', overflowWrap: 'anywhere' });
      body.appendChild(title);
      var presence = place.getAttribute('data-presence');
      if (presence) {
        var online = presence === 'online';
        var line = cardLine(online ? 'Online now' : 'Away');
        Object.assign(line.style, { display: 'flex', alignItems: 'center', gap: '6px' });
        var dot = document.createElement('span');
        paintDot(dot, online);
        line.insertBefore(dot, line.firstChild);
        body.appendChild(line);
      }
      var joined = place.getAttribute('data-joined');
      if (joined) body.appendChild(cardLine(joinedWords(joined)));
    }
    function fill(into, mode) {
      var body = document.createElement('div');
      into.appendChild(body);
      var start = document.createElement('div');
      topic.mount(start);
      var topics = topicLinks(list);
      if (mode === 'new') {
        body.appendChild(start);
        body.appendChild(cardHeading('Topics', '18px'));
        body.appendChild(topics);
      } else {
        about(body);
        body.appendChild(cardHeading('Topics', '14px'));
        body.appendChild(topics);
        start.style.marginTop = '18px';
        body.appendChild(start);
      }
      body.addEventListener('keydown', function (e) {
        if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
        var stops = [topic.input].concat(Array.prototype.slice.call(body.querySelectorAll('.popup-topic')));
        var at = stops.indexOf(document.activeElement);
        if (at === -1) return;
        e.preventDefault();
        e.stopPropagation();
        var next = stops[Math.max(0, Math.min(stops.length - 1, at + (e.key === 'ArrowDown' ? 1 : -1)))];
        next.focus();
      });
    }
    return { open: open, fill: fill };
  }

  // The people popup, opened by the DMs group's "more" row (`opener`): the
  // DMs the sidebar keeps out of sight (app/DmShortlist.roc), `people`, each
  // `{ label, place, card }`, in the sidebar's order. A filter field at its
  // top, focused, keeps those whose name holds what is typed, in any case;
  // Enter with one left opens it. Choosing a person shows their card in this
  // same popup, with a way back to the list, since no popup opens another.
  // It is a popup and not a list in the sidebar because every human of the
  // chat is a DM, so the list grows with the chat, and a field in the
  // sidebar itself is clutter.
  function peoplePopup(people, opener) {
    function open() {
      var popup = frame('people-popup', 'People', opener);
      var filter = document.createElement('input');
      filter.type = 'search';
      filter.placeholder = 'Filter by name';
      filter.setAttribute('aria-label', 'Filter people by name');
      Object.assign(filter.style, {
        boxSizing: 'border-box', width: '100%', fontFamily: 'inherit', fontSize: '14px', padding: '6px 8px',
        background: 'var(--cc-bg)', color: 'var(--cc-fg)', border: '1px solid var(--cc-input-border)', borderRadius: '6px',
      });
      var rows = document.createElement('div');
      Object.assign(rows.style, { margin: '8px 0 0', maxHeight: '50vh', overflowY: 'auto' });
      function matching() {
        var typed = filter.value.trim().toLowerCase();
        return people.filter(function (person) { return person.label.toLowerCase().indexOf(typed) !== -1; });
      }
      function showCard(person) {
        popup.body.textContent = '';
        var back = document.createElement('button');
        back.type = 'button';
        back.textContent = '← All people';
        back.className = 'popup-secondary';
        back.style.marginBottom = '14px';
        back.addEventListener('click', showList);
        popup.body.appendChild(back);
        person.card.fill(popup.body, 'about');
        back.focus();
      }
      function listRows() {
        rows.textContent = '';
        var shown = matching();
        if (shown.length === 0) {
          var none = cardLine('No one matches.');
          none.style.color = 'var(--cc-muted-fg)';
          rows.appendChild(none);
        }
        shown.forEach(function (person) {
          var row = document.createElement('div');
          row.setAttribute('role', 'button');
          row.setAttribute('tabindex', '0');
          Object.assign(row.style, {
            display: 'flex', alignItems: 'center', gap: '8px', padding: '6px 8px', borderRadius: '6px',
            fontSize: '14px', cursor: 'pointer', overflowWrap: 'anywhere',
          });
          var presence = person.place.getAttribute('data-presence');
          if (presence) {
            var dot = document.createElement('span');
            paintDot(dot, presence === 'online');
            row.appendChild(dot);
          }
          row.appendChild(document.createTextNode(person.label));
          row.addEventListener('mouseenter', function () { row.style.background = 'var(--cc-accent-soft-bg)'; });
          row.addEventListener('mouseleave', function () { row.style.background = 'transparent'; });
          row.addEventListener('click', function () { showCard(person); });
          row.addEventListener('keydown', function (e) {
            if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); showCard(person); }
          });
          rows.appendChild(row);
        });
      }
      function showList() {
        popup.body.textContent = '';
        popup.body.appendChild(filter);
        popup.body.appendChild(rows);
        listRows();
        filter.focus();
      }
      filter.addEventListener('input', listRows);
      filter.addEventListener('keydown', function (e) {
        if (e.key !== 'Enter') return;
        e.preventDefault();
        var shown = matching();
        if (shown.length === 1) showCard(shown[0]);
      });
      popup.show();
      showList();
    }
    return { open: open };
  }

  return { isOpen: isOpen, paintDot: paintDot, topicForm: topicForm, placePopup: placePopup, peoplePopup: peoplePopup };
})();
