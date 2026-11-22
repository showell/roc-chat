// This script runs on a conversation page, which app/ConversationPage.roc
// builds and app/Script.roc serves. It gives each message its actions:
// reacting with an emoji, quoting it in a reply, and editing the viewer's
// own, as chat-client's messages did (js/message.js, js/chat_reactions.js
// and js/chat.js's doQuote and doEdit), and citing it. It runs after
// compose.js, emoji.js, feed.js and citation.js, and feed.js hands it each
// message the stream brings, or brings again (Actions.dress).
//
// The server draws everything a message shows, its reactions and its edit
// included, so this script only styles what it finds and sends what the
// reader asks for. A reaction's button names its reactors' ids
// (data-reactors) and, in its title, their names; the viewer's own are
// highlighted, the title gains what a click does, as chat-client's did
// ("Steve, CC — click to react too"), and a click takes the viewer's
// reaction back, or adds it; a touch held on one shows the names, for a
// phone has no hover (the long press, below). The `+` key toggles 👍 on the
// selected message, as chat-client's did, with no picker. The "react"
// button, or the `:` key on the selected message, opens a picker of
// emoji.js's emojis (Emoji.glyphs). The picker works by keys too: its first
// emoji has the focus, the arrows move it through the grid, Tab and Shift+Tab within the picker,
// Enter or Space picks, and Escape closes it and gives the focus back to
// where it was. A tap picks, as a click does. Each reaction is
// a POST to the messages pane's data-react (`msg`, `emoji`, `on`), and is
// never shown before the server has it: the stream sends the message again,
// drawn with its reactions as they are now, and feed.js puts it in place.
//
// An edit is a new message whose first line is "Edit of " and the
// reference of the message it edits, as chat-client's were. The "edit"
// button, on the viewer's own messages, or the `e` key on the selected
// one, reads the message's markdown as written (the pane's data-raw, with
// `?message=<n>`) and loads the box with that line, a blank line and the
// markdown, the caret after the blank line. Sending it is the box's own
// send. The server marks the original edited and the stream redraws it.
//
// A quote-reply is chat-client's (js/chat.js's doQuote). The "quote-reply"
// button, on every message, or the `q` or `>` key on the selected one (`r` is
// Recent's, compose.js; chat-client's `r` replied too), reads
// the message's markdown as written, as an edit does, opens the box and puts
// at its caret "In <reference> I said:" ("you said:" for another's), the
// markdown in a tilde fence whose language is `quote`, and a blank line, the
// caret after it. roc-markdown draws that fence as a quoted message
// (<pre class="chat-quote">) and the reference as a link to the message.
//
// A reference in a message's markdown, MSG_<topic>_<n>, is roc-markdown's
// link (a.msg-ref) to #msg-<topic>_<n>, which names no element: a message
// here is msg-<n>. A click on one follows it as chat-client's navigateRef
// did (js/chat.js): when its label is the reference of a message on this
// page, as that message's header writes it, the message is brought into
// view and selected (Feed.reveal). A long reference,
// MSG_<channel>.<topic>_<n>, is this page's when its channel is the page's.
// One of this page's topic that names no message here says so. Any other
// names a message on another page, and opens in a new tab at
// /chat/msg/<id>, the id as written, as chat-client's did: the server finds
// where it is (app/MessageLinkRoute.roc), or says it can't.
//
// A citation cites a message in another topic. The "cite" button, on every
// message, or the `l` key on the selected one, copies one to the clipboard
// (citation.js's Citation.copy, which writes it; Citation.mark marks one in a message).
// A link in a message to a message on this page, a citation's in its own
// topic among them, brings it into view and selects it, in place.
//
// The `t` key opens the conversation's raw transcript (the pane's data-raw)
// in a new tab, as chat-client's did (js/chat.js's viewRaw), so a reader
// sees every message's markdown as written. The `d` key downloads the
// conversation as a .tar.gz, its transcript and images (the pane's
// data-download), as chat-client's did (js/chat.js's downloadBundle): the
// server says it is an attachment, so a link's click saves it and the page
// stays.
//
// In a narrow window (chrome.js's layout-narrow), a phone's, the buttons, the
// reactions and the picker's emojis are larger, for a finger, and the
// picker opens across the window's width under the message. There the
// buttons wait behind a "⋯" at the header's right end, so a header is one
// line, the author and the time: a phone is mostly for catching up, and
// four finger-sized buttons on every message cost each one a second line.
// A tap on "⋯" opens the buttons as a row under that message's header, in
// place (no popup), and closes the row open on any other; a tap on "⋯"
// again, or on one of the buttons, closes it. Nothing opens or closes as
// the reader scrolls, so the messages never move under a finger.
(function () {
  'use strict';
  var messages = document.querySelector('.messages');
  if (!messages) throw new Error('actions.js: the page has no .messages');
  if (!window.Keys || !window.Compose) throw new Error('actions.js: keys.js and compose.js run first, and give Keys and Compose');
  if (!window.Emoji) throw new Error('actions.js: emoji.js runs first, and gives Emoji');
  if (!window.Feed) throw new Error('actions.js: feed.js runs first, and gives Feed');
  if (!window.Citation) throw new Error('actions.js: citation.js runs first, and gives Citation');
  var viewer = messages.getAttribute('data-viewer');
  var reactUrl = messages.getAttribute('data-react');
  var rawUrl = messages.getAttribute('data-raw');
  var downloadUrl = messages.getAttribute('data-download');
  if (!viewer || !reactUrl || !rawUrl || !downloadUrl) {
    throw new Error('actions.js: .messages has no data-viewer, no data-react, no data-raw or no data-download');
  }

  var s = document.createElement('style');
  s.textContent = [
    '.message .actions { margin-left: 6px; }',
    '.message .actions button { font: inherit; font-size: 11px; color: var(--cc-muted-fg); background: none;' +
      ' border: none; padding: 0 3px; cursor: pointer; }',
    '.message .actions button:hover { color: var(--cc-accent); text-decoration: underline; }',
    '.reaction-strip { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 6px; }',
    '.reaction-chip { font-size: 12px; line-height: 1.2; padding: 2px 7px; border-radius: 10px; cursor: pointer;' +
      ' background: var(--cc-bg); color: var(--cc-fg); border: 1px solid var(--cc-border); }',
    '.reaction-chip:hover { border-color: var(--cc-accent); }',
    '.reaction-chip.mine { background: var(--cc-accent-soft-bg); border-color: var(--cc-accent); }',
    '.edited-note { font-size: 12px; color: var(--cc-muted-fg); margin: 0 0 4px; }',
    '.edited-original > summary { font-size: 11px; color: var(--cc-muted-fg); cursor: pointer; }',
    '.edited-markdown { font-size: 11px; color: var(--cc-soft-muted-fg); white-space: pre-wrap; overflow-wrap: anywhere;' +
      ' border-left: 3px solid var(--cc-border); padding: 2px 0 2px 8px; margin-top: 4px; }',
    '.reaction-picker { position: fixed; z-index: 10; display: flex; flex-wrap: wrap; gap: 2px; max-width: 220px;' +
      ' padding: 6px; border-radius: 8px; border: 1px solid var(--cc-border); background: var(--cc-card-bg);' +
      ' box-shadow: 0 4px 12px rgba(0, 0, 0, 0.25); }',
    '.reaction-picker button { font-size: 18px; background: none; border: none; padding: 2px 4px; cursor: pointer; border-radius: 4px; }',
    '.reaction-picker button:hover { background: var(--cc-accent-soft-bg); }',
    '.reaction-picker button:focus-visible { background: var(--cc-accent-soft-bg); outline: 2px solid var(--cc-accent);' +
      ' outline-offset: -2px; }',
    '.message .actions-more { display: none; }',
    'html.layout-narrow .message .actions-more { display: inline; float: right; font: inherit; font-size: 16px; line-height: 1;' +
      ' color: var(--cc-muted-fg); background: none; border: none; padding: 0 4px 2px 12px; cursor: pointer; }',
    'html.layout-narrow .message.actions-open .actions-more { color: var(--cc-accent); }',
    'html.layout-narrow .message:not(.actions-open) .actions { display: none; }',
    'html.layout-narrow .message.actions-open .actions { display: flex; flex-wrap: wrap; gap: 4px; margin: 4px 0 0 -8px; }',
    'html.layout-narrow .message .actions button { font-size: 13px; padding: 6px 8px; }',
    'html.layout-narrow .reaction-chip { font-size: 14px; padding: 5px 10px; border-radius: 14px; }',
    'html.layout-narrow .reaction-picker { max-width: none; gap: 4px; }',
    'html.layout-narrow .reaction-picker button { font-size: 24px; padding: 6px 8px; }',
    '@media (hover: none) { .reaction-chip { -webkit-touch-callout: none; -webkit-user-select: none; user-select: none; } }',
    '.reactors-popover { position: fixed; z-index: 12; max-width: 260px; padding: 6px 10px; border-radius: 8px; font-size: 14px;' +
      ' line-height: 1.3; color: var(--cc-fg); background: var(--cc-card-bg); border: 1px solid var(--cc-border);' +
      ' box-shadow: 0 4px 12px rgba(0, 0, 0, 0.25); pointer-events: none; }',
    '.action-failed { position: fixed; z-index: 11; bottom: 16px; left: 50%; transform: translateX(-50%);' +
      ' padding: .5rem .75rem; border-radius: 6px; background: var(--cc-lost-bg); color: var(--cc-lost-fg); }',
  ].join('\n');
  document.head.appendChild(s);

  // The message's number, from its id, msg-<n>.
  function numberOf(article) { return article.id.replace(/^msg-/, ''); }
  function isMine(article) { return article.getAttribute('data-author') === viewer; }
  function reactorsOf(chip) { return (chip.getAttribute('data-reactors') || '').split('-'); }
  // The reactors' names, as the server's title gives them, without the
  // click hint dress adds after HINT_SEPARATOR.
  var HINT_SEPARATOR = ' — ';
  function namesOf(chip) { return chip.title.split(HINT_SEPARATOR)[0]; }
  function emojiOf(chip) {
    var glyph = chip.querySelector('.reaction-emoji');
    return glyph ? glyph.textContent : '';
  }
  // Whether the viewer has reacted to `article` with `emoji`.
  function reacted(article, emoji) {
    var chips = article.querySelectorAll('.reaction-chip');
    for (var i = 0; i < chips.length; i++) {
      if (emojiOf(chips[i]) === emoji) return reactorsOf(chips[i]).indexOf(viewer) >= 0;
    }
    return false;
  }

  function showFailure(words) {
    var old = document.querySelector('.action-failed');
    if (old) old.remove();
    var notice = document.createElement('p');
    notice.className = 'action-failed';
    notice.textContent = words;
    document.body.appendChild(notice);
    setTimeout(function () { notice.remove(); }, 4000);
  }

  // The viewer's reaction `emoji` to `article`, added, or taken back when
  // it is there.
  function toggle(article, emoji) {
    var form = new URLSearchParams();
    form.set('msg', numberOf(article));
    form.set('emoji', emoji);
    form.set('on', reacted(article, emoji) ? '0' : '1');
    fetch(reactUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
    }).then(function (r) {
      if (r.ok) return;
      return r.text().then(function (text) { showFailure('Reaction refused: ' + text.trim()); });
    }).catch(function () { showFailure('Reaction failed: the server did not answer.'); });
  }

  var picker = null;
  // What had the focus before the picker opened, given it back on Escape.
  var focusBefore = null;
  function closePicker() {
    if (picker) picker.remove();
    picker = null;
  }
  // The picker's emoji `delta` away from the focused one: ±1 along a row,
  // and a row's width up or down, the width read from where they wrapped.
  function moveFocus(delta) {
    var buttons = Array.prototype.slice.call(picker.querySelectorAll('button'));
    var at = buttons.indexOf(document.activeElement);
    var perRow = buttons.filter(function (b) { return b.offsetTop === buttons[0].offsetTop; }).length;
    var step = delta === 'down' ? perRow : delta === 'up' ? -perRow : delta;
    var next = at < 0 ? 0 : at + step;
    if (Math.abs(step) === 1) next = (next + buttons.length) % buttons.length;
    if (next >= 0 && next < buttons.length) buttons[next].focus();
  }
  var PICKER_MOVES = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: 'up', ArrowDown: 'down' };
  function pickerKey(e) {
    if (e.key === 'Escape') {
      closePicker();
      if (focusBefore && document.contains(focusBefore)) focusBefore.focus();
    } else if (PICKER_MOVES[e.key] !== undefined) {
      moveFocus(PICKER_MOVES[e.key]);
    } else if (e.key === 'Tab') {
      moveFocus(e.shiftKey ? -1 : 1);
    } else if (e.key === 'Enter' || e.key === ' ') {
      if (picker.contains(document.activeElement)) document.activeElement.click();
    } else {
      return;
    }
    // Handled here: the page's keys (Keys, feed.js's arrows) never see it.
    e.preventDefault();
    e.stopPropagation();
  }
  function openPicker(article) {
    closePicker();
    focusBefore = document.activeElement;
    picker = document.createElement('div');
    picker.className = 'reaction-picker';
    picker.setAttribute('role', 'menu');
    picker.addEventListener('keydown', pickerKey);
    Emoji.glyphs.forEach(function (emoji) {
      var b = document.createElement('button');
      b.type = 'button';
      b.textContent = emoji;
      b.addEventListener('click', function () {
        closePicker();
        toggle(article, emoji);
      });
      picker.appendChild(b);
    });
    var box = article.getBoundingClientRect();
    if (document.documentElement.classList.contains('layout-narrow')) {
      picker.style.left = '8px';
      picker.style.right = '8px';
    } else {
      picker.style.left = Math.max(8, Math.min(box.left, window.innerWidth - 240)) + 'px';
    }
    document.body.appendChild(picker);
    var height = picker.getBoundingClientRect().height;
    picker.style.top = Math.max(8, Math.min(box.top + 20, window.innerHeight - height - 8)) + 'px';
    picker.querySelector('button').focus();
  }
  document.addEventListener('click', function (e) {
    if (picker && !picker.contains(e.target) && !(e.target.closest && e.target.closest('.react-open'))) closePicker();
  });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closePicker(); });

  // The tilde fence a quote wraps `markdown` in: one longer than its longest
  // line-opening run of tildes, at least three, so a quote of a quote stays
  // whole (chat-client's pickQuoteFence).
  function quoteFence(markdown) {
    var runs = markdown.match(/^~{3,}/gm) || [];
    var longest = runs.reduce(function (most, run) { return Math.max(most, run.length); }, 2);
    return '~'.repeat(longest + 1);
  }

  // Puts a quote-reply of `article` at the box's caret, as chat-client's
  // doQuote did: "In <reference> I said:" (or "you said:", another's), its
  // markdown in a `quote` fence, a blank line, and the caret after it.
  function quote(article) {
    var ref = article.querySelector('header .message-reference');
    if (!ref) return;
    fetch(rawUrl + '?message=' + numberOf(article)).then(function (r) {
      return r.text().then(function (text) {
        if (!r.ok) {
          showFailure('The message could not be read: ' + text.trim());
          return;
        }
        var fence = quoteFence(text);
        var said = isMine(article) ? 'I said' : 'you said';
        Compose.insert('In ' + ref.textContent + ' ' + said + ':\n' + fence + ' quote\n' + text + '\n' + fence + '\n\n');
      });
    }).catch(function () { showFailure('The message could not be read: the server did not answer.'); });
  }

  // Loads the box with an edit of `article`, the viewer's own.
  function edit(article) {
    if (!isMine(article)) return;
    var ref = article.querySelector('header .message-reference');
    if (!ref) return;
    fetch(rawUrl + '?message=' + numberOf(article)).then(function (r) {
      return r.text().then(function (text) {
        if (!r.ok) {
          showFailure('The message could not be read: ' + text.trim());
          return;
        }
        var first = 'Edit of ' + ref.textContent + '\n\n';
        Compose.load(first + text, first.length);
      });
    }).catch(function () { showFailure('The message could not be read: the server did not answer.'); });
  }

  // What the script adds to a message the server drew: its action buttons,
  // and the viewer's own reactions marked.
  function dress(article) {
    Citation.mark(article);
    if (popoverChip && !document.contains(popoverChip)) closePopover(); // the stream redrew its chip
    var chips = article.querySelectorAll('.reaction-chip');
    for (var i = 0; i < chips.length; i++) {
      var mine = reactorsOf(chips[i]).indexOf(viewer) >= 0;
      chips[i].type = 'button';
      chips[i].classList.toggle('mine', mine);
      chips[i].title = namesOf(chips[i]) + HINT_SEPARATOR + (mine ? 'click to take your reaction back' : 'click to react too');
    }
    var header = article.querySelector('header');
    if (!header || header.querySelector('.actions')) return;
    var actions = document.createElement('span');
    actions.className = 'actions';
    var react = document.createElement('button');
    react.type = 'button';
    react.className = 'react-open';
    react.textContent = 'react';
    react.title = 'React with an emoji (:)';
    actions.appendChild(react);
    var quoteButton = document.createElement('button');
    quoteButton.type = 'button';
    quoteButton.className = 'quote-open';
    quoteButton.textContent = 'quote-reply';
    quoteButton.title = 'Quote this message in a reply (q)';
    actions.appendChild(quoteButton);
    var citeButton = document.createElement('button');
    citeButton.type = 'button';
    citeButton.className = 'cite-open';
    citeButton.textContent = 'cite';
    citeButton.title = 'Copy a citation of this message, to paste in any topic (l)';
    actions.appendChild(citeButton);
    if (isMine(article)) {
      var editButton = document.createElement('button');
      editButton.type = 'button';
      editButton.className = 'edit-open';
      editButton.textContent = 'edit';
      editButton.title = 'Load this message into the compose box as an edit (e)';
      actions.appendChild(editButton);
    }
    var more = document.createElement('button');
    more.type = 'button';
    more.className = 'actions-more';
    more.textContent = '⋯';
    more.title = 'Actions';
    more.setAttribute('aria-label', 'Actions');
    more.setAttribute('aria-expanded', 'false');
    header.appendChild(more);
    header.appendChild(actions);
  }

  // A phone's row of buttons under one message's header ("⋯"), opened or
  // closed; opening one closes the row open on any other.
  function showActions(article, open) {
    var shown = messages.querySelectorAll('.message.actions-open');
    for (var i = 0; i < shown.length; i++) {
      if (shown[i] !== article) showActions(shown[i], false);
    }
    article.classList.toggle('actions-open', open);
    var more = article.querySelector('.actions-more');
    if (more) more.setAttribute('aria-expanded', open ? 'true' : 'false');
  }

  // The page's channel, on a channel's page (/chat/channel/<name>/<topic>);
  // null on a DM's. And its topic, on either, as the messages pane names it.
  var channelAt = /^\/chat\/channel\/([^\/]+)\//.exec(location.pathname);
  var channel = channelAt ? decodeURIComponent(channelAt[1]) : null;
  var topic = messages.getAttribute('data-topic');
  if (!topic) throw new Error('actions.js: .messages has no data-topic');
  // Where the server follows a link to a message on another page.
  var MESSAGE_LINK_PATH = '/chat/msg/';
  // The reference `label` as this page's headers write it: a long one's
  // channel dropped when it is the page's.
  function shortReference(label) {
    var long = /^MSG_([A-Za-z][A-Za-z0-9-]{0,39})\.([A-Za-z0-9-]+_[0-9]+)$/.exec(label);
    if (!long) return label;
    return long[1] === channel ? 'MSG_' + long[2] : null;
  }
  function followReference(link) {
    var label = link.textContent;
    var wanted = shortReference(label);
    var refs = messages.querySelectorAll('.message header .message-reference');
    for (var i = 0; wanted && i < refs.length; i++) {
      if (refs[i].textContent === wanted) {
        Feed.reveal(refs[i].closest('.message'));
        return;
      }
    }
    var short = wanted && /^MSG_([A-Za-z0-9-]+)_[0-9]+$/.exec(wanted);
    if (short && short[1] === topic) {
      showFailure(label + ' is not in this topic.');
      return;
    }
    window.open(MESSAGE_LINK_PATH + encodeURIComponent(label.replace(/^MSG_/, '')), '_blank', 'noopener');
  }

  // A link in a message to a message on this page, a citation's in its own
  // topic among them, brings it into view and selects it, in place.
  function messageHere(link) {
    if (link.origin !== location.origin || link.pathname !== location.pathname) return null;
    if (!/^#msg-[0-9]+$/.test(link.hash)) return null;
    var named = document.getElementById(link.hash.slice(1));
    return named && messages.contains(named) ? named : null;
  }

  // A phone has no hover, so a long press on a reaction shows who reacted
  // (owner, 2026-11-22): a touch held PRESS_MS on a chip, the finger moving
  // at most SLOP_PX, opens a popover over the chip with the names its title
  // gives (namesOf), and that touch's click, which would toggle the
  // reaction, is cancelled. A shorter touch is a tap, and toggles as a
  // click does; a touch that moves is a scroll, and does neither. The
  // popover closes at the next touch or mouse press anywhere, on any
  // scroll, after POPOVER_MS, or when the stream redraws its chip; one
  // shows at a time. A chip's own long-press behaviours, the callout and
  // text selection, are off where nothing hovers, and its context menu
  // while it is pressed. A mouse sends no touch events, so a desktop keeps
  // its hover title and its click.
  var PRESS_MS = 500;
  var SLOP_PX = 10;
  var POPOVER_MS = 4000;
  var press = null; // {x, y, timer}: a touch on a chip, not yet a long press
  var pressedChip = null; // the chip a long press opened over, until its click is cancelled
  var popover = null;
  var popoverChip = null;
  var popoverTimer = null;

  function closePopover() {
    if (popoverTimer) clearTimeout(popoverTimer);
    if (popover) popover.remove();
    popover = popoverChip = popoverTimer = null;
  }
  function openPopover(chip) {
    closePopover();
    popover = document.createElement('div');
    popover.className = 'reactors-popover';
    popover.setAttribute('role', 'tooltip');
    popover.textContent = namesOf(chip);
    document.body.appendChild(popover);
    popoverChip = chip;
    var at = chip.getBoundingClientRect();
    var size = popover.getBoundingClientRect();
    var top = at.top - size.height - 6;
    if (top < 8) top = at.bottom + 6;
    popover.style.left = Math.max(8, Math.min(at.left, window.innerWidth - size.width - 8)) + 'px';
    popover.style.top = top + 'px';
    popoverTimer = setTimeout(closePopover, POPOVER_MS);
  }
  function cancelPress() {
    if (press) clearTimeout(press.timer);
    press = null;
  }
  document.addEventListener('touchstart', function (e) {
    closePopover();
    cancelPress();
    pressedChip = null;
    var chip = e.touches.length === 1 && e.target.closest && e.target.closest('.reaction-chip');
    if (!chip || !messages.contains(chip)) return;
    var t = e.touches[0];
    press = { x: t.clientX, y: t.clientY, timer: setTimeout(function () {
      press = null;
      // A chip the stream redrew under the finger gets the touch's end, which
      // never reaches the document, so a tap on it may look held: no popover.
      if (!document.contains(chip)) return;
      pressedChip = chip;
      openPopover(chip);
    }, PRESS_MS) };
  }, { passive: true });
  document.addEventListener('touchmove', function (e) {
    if (!press) return;
    var t = e.touches[0];
    if (Math.abs(t.clientX - press.x) > SLOP_PX || Math.abs(t.clientY - press.y) > SLOP_PX) cancelPress();
  }, { passive: true });
  document.addEventListener('touchcancel', cancelPress);
  document.addEventListener('touchend', function (e) {
    cancelPress();
    if (pressedChip) e.preventDefault(); // no click, so no toggle
  });
  document.addEventListener('scroll', function () { cancelPress(); closePopover(); }, true);
  document.addEventListener('mousedown', closePopover);
  messages.addEventListener('contextmenu', function (e) {
    if ((press || pressedChip) && e.target.closest && e.target.closest('.reaction-chip')) e.preventDefault();
  });

  messages.addEventListener('click', function (e) {
    var article = e.target.closest && e.target.closest('.message');
    if (!article) return;
    var reference = e.target.closest('a.msg-ref');
    if (reference) {
      e.preventDefault();
      followReference(reference);
      return;
    }
    var link = e.target.closest('.body a[href]');
    var cited = link && messageHere(link);
    if (cited) {
      e.preventDefault();
      Feed.reveal(cited);
      return;
    }
    var chip = e.target.closest('.reaction-chip');
    if (chip) {
      // A long press's click, should touchend's cancel not have stopped it.
      if (chip === pressedChip) { pressedChip = null; return; }
      toggle(article, emojiOf(chip));
      return;
    }
    if (e.target.closest('.actions-more')) { showActions(article, !article.classList.contains('actions-open')); return; }
    if (e.target.closest('.actions button')) showActions(article, false);
    if (e.target.closest('.react-open')) { openPicker(article); return; }
    if (e.target.closest('.quote-open')) { quote(article); return; }
    if (e.target.closest('.cite-open')) { Citation.copy(article); return; }
    if (e.target.closest('.edit-open')) edit(article);
  });

  function selectedMessage() { return messages.querySelector('.message.selected'); }
  Keys.register({ key: ':', label: 'react to the selected message', run: function () {
    var article = selectedMessage();
    if (article) openPicker(article);
  } });
  Keys.register({ key: '+', label: 'thumbs-up the selected message', run: function () {
    var article = selectedMessage();
    if (article) toggle(article, Emoji.glyphOf('thumbsup'));
  } });
  Keys.register({ key: 'e', label: 'edit the selected message, if yours', run: function () {
    var article = selectedMessage();
    if (article) edit(article);
  } });
  function quoteSelected() {
    var article = selectedMessage();
    if (article) quote(article);
  }
  Keys.register({ key: 'q', label: 'quote-reply to the selected message', aliases: ['>'], run: quoteSelected });
  Keys.register({ key: 'l', label: 'link: copy a citation link to the selected message', run: function () {
    var article = selectedMessage();
    if (article) Citation.copy(article);
  } });
  Keys.register({ key: 't', label: 'transcript: open the raw transcript in a new tab', run: function () {
    window.open(rawUrl, '_blank');
  } });
  Keys.register({ key: 'd', label: 'download the transcript + images (.tar.gz)', run: function () {
    var a = document.createElement('a');
    a.href = downloadUrl;
    document.body.appendChild(a);
    a.click();
    a.remove();
  } });

  var drawn = messages.querySelectorAll('.message');
  for (var j = 0; j < drawn.length; j++) dress(drawn[j]);
  window.Actions = { dress: dress };
})();
