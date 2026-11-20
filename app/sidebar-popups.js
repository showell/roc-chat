// This script runs on a conversation page that has a sidebar, before
// app/sidebar.js, which opens its popups. app/Script.roc serves it. Each
// popup is a modal dialog over a dimmed page, as feed.js's code popup is: a
// strap at its top with its heading and a Close button, made afresh at each
// opening and removed once closed, the focus going back to what opened it.
// Escape, Close, or a click outside it closes it. A dialog sits above the
// phone's drawer, so each works there too.
//
// The new-topic popup holds a place's form, its field focused: Enter adds
// the topic, and Escape or Close cancels. The form posts as it always has,
// to the place's path, but by fetch: a topic the server takes answers with
// its page, which the browser then opens; one it refuses answers with
// Browse, whose problem paragraph (.problem) the popup shows, keeping what
// was typed.
//
// The person popup is a DM's card about its person, opened by their name:
// their full name, whether they are online now (the place's data-presence,
// which sidebar.js keeps up to date), when they joined when the server says
// (data-joined, seconds since 1970, shown as a date in the viewer's own
// time), then the DM's topics as small links straight to each, and the
// place's new-topic form itself, its field and its button: a popup is
// roomy, so its action is in it, and no popup opens another (Steve,
// 2026-11-20). Enter adds the topic, as in the "+" popup, and a refusal
// shows under the form; Escape closes the card.
//
// SidebarPopups.paintDot is the presence dot, chat-client's: a hollow ring
// while the person is away, solid green while they are online. Its colours
// are palette.js's.
window.SidebarPopups = (function () {
  'use strict';
  var backdropRule = document.createElement('style');
  backdropRule.textContent = 'dialog.topic-popup::backdrop, dialog.person-popup::backdrop { background: var(--cc-backdrop); }';
  document.head.appendChild(backdropRule);

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

  // A popup's frame: a dialog `width` wide, its strap headed `words`, and
  // its body padded `padding`. `show` opens it; once closed it is removed
  // and the focus goes back to `opener`.
  function frame(className, words, width, padding, opener) {
    var dlg = document.createElement('dialog');
    dlg.className = className;
    Object.assign(dlg.style, {
      width: width, padding: '0', border: '1px solid var(--cc-dialog-border)', borderRadius: '8px',
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
    body.style.padding = padding;
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

  // A place's new-topic popup, `form` headed `words`, giving the focus back
  // to `plus`. The form is posted by fetch, so a refusal stays in the popup.
  function topicPopup(form, words, plus) {
    var input = form.querySelector('input');
    var submit = form.querySelector('button');
    if (!input || !submit) throw new Error('sidebar-popups.js: a new-topic form has no input or button');
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
    // The form, and the line that says a refusal, put fresh into `into`:
    // the "+" popup's body, or a person card's. One popup is open at a time,
    // so the one form moves to whichever holds it.
    function mount(into) {
      problem.textContent = '';
      submit.disabled = false;
      form.style.margin = '0';
      into.appendChild(form);
      into.appendChild(problem);
    }
    function open() {
      var popup = frame('topic-popup', words, 'min(320px, 90vw)', '12px 14px', plus);
      mount(popup.body);
      popup.show();
      input.focus();
      input.select();
    }
    return { open: open, mount: mount };
  }

  // A small muted line of the person card.
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

  // The person card of the DM `place`, named `who`, its topics `list`,
  // giving the focus back to `name`. The place's new-topic form is in the
  // card itself, under its topics (`topic`, the place's topicPopup, puts it
  // there): a popup is roomy, so its action is right in it, never behind a
  // second popup (Steve, 2026-11-20). Enter adds the topic; Escape closes
  // the card.
  function personPopup(place, who, list, name, topic) {
    function open() {
      var popup = frame('person-popup', '', 'min(380px, 92vw)', '16px 18px 18px', name);
      var title = document.createElement('p');
      title.textContent = who;
      Object.assign(title.style, { margin: '0 0 8px', fontSize: '17px', fontWeight: 'bold', overflowWrap: 'anywhere' });
      popup.body.appendChild(title);
      var presence = place.getAttribute('data-presence');
      if (presence) {
        var online = presence === 'online';
        var line = cardLine(online ? 'Online now' : 'Away');
        Object.assign(line.style, { display: 'flex', alignItems: 'center', gap: '6px' });
        var dot = document.createElement('span');
        paintDot(dot, online);
        line.insertBefore(dot, line.firstChild);
        popup.body.appendChild(line);
      }
      var joined = place.getAttribute('data-joined');
      if (joined) popup.body.appendChild(cardLine(joinedWords(joined)));

      var topicsHeading = cardLine('Topics');
      Object.assign(topicsHeading.style, {
        margin: '14px 0 6px', fontSize: '11px', fontWeight: '600', letterSpacing: '0.06em',
        textTransform: 'uppercase', color: 'var(--cc-muted-fg)',
      });
      popup.body.appendChild(topicsHeading);
      var links = list.querySelectorAll('li a');
      if (links.length === 0) {
        var none = cardLine('No topics yet.');
        none.style.color = 'var(--cc-muted-fg)';
        popup.body.appendChild(none);
      } else {
        var topics = document.createElement('div');
        Object.assign(topics.style, { display: 'flex', flexWrap: 'wrap', gap: '4px 14px', fontSize: '12px' });
        links.forEach(function (shown) {
          var link = document.createElement('a');
          link.href = shown.getAttribute('href');
          link.textContent = shown.textContent;
          Object.assign(link.style, { color: 'var(--cc-accent)', textDecoration: 'none', overflowWrap: 'anywhere' });
          link.addEventListener('mouseenter', function () { link.style.textDecoration = 'underline'; });
          link.addEventListener('mouseleave', function () { link.style.textDecoration = 'none'; });
          topics.appendChild(link);
        });
        popup.body.appendChild(topics);
      }

      var start = document.createElement('div');
      start.style.marginTop = '16px';
      topic.mount(start);
      popup.body.appendChild(start);
      popup.show();
    }
    return { open: open };
  }

  return { isOpen: isOpen, paintDot: paintDot, topicPopup: topicPopup, personPopup: personPopup };
})();
