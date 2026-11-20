// This script runs on a conversation page, which app/ConversationPage.roc
// builds and app/Script.roc serves. It writes and reads citations: a way to
// cite a message of one topic in another (Steve, 2026-11-20). It runs after
// compose.js and feed.js and before actions.js, which gives each message
// its "cite" button and registers the `l` key, both Citation.copy, and hands
// it each message drawn (Citation.mark).
//
// A citation is plain markdown, so the transcript's format is unchanged:
// the message's markdown as written, at most its first three lines or
// about 280 characters, whichever comes first, a cut one ending in "…",
// each line quoted with `> `; a blank line; and a link, "<author> in
// <place> › <topic>", the place and topic as the page names them on its
// messages pane (data-place: `#channel`, a DM's other human, or the viewer
// on their own DM; data-topic), to the message on this topic's own page
// (its path and #msg-<n>).
// Copied, the status line says "✓ citation copied: paste it in any topic";
// with the compose box open here, where a quote-reply is the better answer,
// it says how to give one instead. While the box is closed, the status
// line can't be seen, so the words show at the window's foot. A clipboard
// the browser refuses says so, and opens a dialog holding the citation,
// selected, to copy by hand.
//
// Where a citation is pasted, roc-markdown draws its quote as a blockquote
// and its link as a paragraph after it. A paragraph right after a quote that
// holds nothing but a link to a chat page is marked citation-link and
// styled small and quiet. Following the link opens the message in its
// topic, selected (feed.js); one to this page's own topic brings it into
// view in place (actions.js).
(function () {
  'use strict';
  var messages = document.querySelector('.messages');
  if (!messages) throw new Error('citation.js: the page has no .messages');
  if (!window.Compose || !window.Viewport) throw new Error('citation.js: chrome.js and compose.js run first, and give Viewport and Compose');
  var rawUrl = messages.getAttribute('data-raw');
  if (!rawUrl) throw new Error('citation.js: .messages has no data-raw');
  var place = messages.getAttribute('data-place');
  var topic = messages.getAttribute('data-topic');
  if (!place || !topic) throw new Error('citation.js: .messages has no data-place or no data-topic');

  var s = document.createElement('style');
  s.textContent = [
    '.message .body blockquote { margin: 6px 0; padding: 2px 10px; border-left: 3px solid var(--cc-quote-border);' +
      ' background: var(--cc-quote-bg); border-radius: 0 4px 4px 0; color: var(--cc-body-muted-fg); }',
    '.message .body p.citation-link { font-size: 11px; margin-top: 2px; }',
    '.message .body p.citation-link a { color: var(--cc-muted-fg); }',
    '.cite-notice { position: fixed; z-index: 11; bottom: 16px; left: 50%; transform: translateX(-50%);' +
      ' padding: .5rem .75rem; border-radius: 6px; background: var(--cc-card-bg); color: var(--cc-notify-fg);' +
      ' border: 1px solid var(--cc-border); }',
    '.cite-notice.failed { background: var(--cc-lost-bg); color: var(--cc-lost-fg); border: none; }',
    '.citation-by-hand { max-width: 90vw; width: 480px; border: 1px solid var(--cc-dialog-border); background: var(--cc-bg);' +
      ' color: var(--cc-fg); border-radius: 8px; padding: 16px 18px; }',
    '.citation-by-hand::backdrop { background: var(--cc-backdrop); }',
    '.citation-by-hand textarea { box-sizing: border-box; width: 100%; font: inherit; font-size: 13px; margin: 10px 0; }',
  ].join('\n');
  document.head.appendChild(s);

  // `words` in the compose box's status line, or for 4 seconds at the
  // window's foot while the box is closed or a send is on its way.
  function tell(words, failed) {
    if (Compose.notice(words, failed)) return;
    var old = document.querySelector('.cite-notice');
    if (old) old.remove();
    var notice = document.createElement('p');
    notice.className = 'cite-notice' + (failed ? ' failed' : '');
    notice.textContent = words;
    document.body.appendChild(notice);
    setTimeout(function () { notice.remove(); }, 4000);
  }

  // A citation's quote: the first CITE_LINES lines of `markdown`, or its
  // first CITE_CHARS characters (to a space where one is near), whichever is
  // less, "…" ending a cut one, and each line given its `> `.
  var CITE_LINES = 3;
  var CITE_CHARS = 280;
  function quoteOf(markdown) {
    var whole = markdown.replace(/\s+$/, '');
    var kept = whole.split('\n').slice(0, CITE_LINES).join('\n');
    if (kept.length > CITE_CHARS) {
      kept = kept.slice(0, CITE_CHARS).replace(/[\uD800-\uDBFF]$/, '');
      var space = kept.lastIndexOf(' ');
      if (space > CITE_CHARS / 2) kept = kept.slice(0, space);
    }
    kept = kept.replace(/\s+$/, '');
    if (kept.length < whole.length) kept += '…';
    return kept.split('\n').map(function (line) { return line ? '> ' + line : '>'; }).join('\n');
  }
  // A citation's link to `article`. roc-markdown takes no `\[` in a link's
  // text, so a bracket in a name is a parenthesis.
  function linkTo(article) {
    var author = article.querySelector('header .author');
    if (!author) throw new Error('citation.js: a message has no header .author');
    var label = (author.textContent.trim() + ' in ' + place + ' › ' + topic).replace(/\[/g, '(').replace(/\]/g, ')');
    return '[' + label + '](' + location.pathname + '#' + article.id + ')';
  }

  // Writes the text `citation` will be to the clipboard. A ClipboardItem
  // takes the promise, so the write starts while the key press or the tap
  // still counts as the reader's, as Safari asks.
  function writeClipboard(citation) {
    var clip = navigator.clipboard;
    if (!clip) return Promise.reject(new Error('no clipboard'));
    if (window.ClipboardItem && clip.write) {
      var blob = citation.then(function (text) { return new Blob([text], { type: 'text/plain' }); });
      return clip.write([new ClipboardItem({ 'text/plain': blob })]);
    }
    return citation.then(function (text) { return clip.writeText(text); });
  }
  // A dialog holding the citation, selected, for the reader to copy by hand.
  function copyByHand(text) {
    var dialog = document.createElement('dialog');
    dialog.className = 'citation-by-hand';
    var said = document.createElement('div');
    said.textContent = 'The browser would not let the page copy. Copy the citation below by hand ' +
      '(Ctrl+C, or ⌘+C on a Mac; on a phone, press and hold), then close this.';
    var area = document.createElement('textarea');
    area.readOnly = true;
    area.rows = 6;
    area.value = text;
    var close = document.createElement('button');
    close.type = 'button';
    close.textContent = 'Close';
    close.addEventListener('click', function () { dialog.close(); });
    dialog.append(said, area, close);
    dialog.addEventListener('close', function () { dialog.remove(); });
    document.body.appendChild(dialog);
    dialog.showModal();
    area.focus();
    area.select();
  }

  // Copies a citation of `article`, reading its markdown as written (the
  // pane's data-raw, with `?message=<n>`, as a quote-reply does), and says so.
  function copy(article) {
    var link = linkTo(article);
    var citation = fetch(rawUrl + '?message=' + article.id.replace(/^msg-/, '')).then(function (r) {
      return r.text().then(function (text) {
        if (!r.ok) throw new Error('The message could not be read: ' + text.trim());
        return quoteOf(text) + '\n\n' + link + '\n';
      });
    });
    writeClipboard(citation).then(function () {
      var quoteHow = Viewport.isNarrow() ? 'tap quote-reply' : 'press q';
      tell(Compose.isOpen() ? '✓ citation copied. To answer it here, ' + quoteHow : '✓ citation copied: paste it in any topic');
    }, function () {
      citation.then(function (text) {
        tell('The browser would not let the page copy the citation: copy it by hand.', true);
        copyByHand(text);
      }, function (err) {
        tell(err instanceof TypeError ? 'The message could not be read: the server did not answer.' : err.message, true);
      });
    });
  }

  // Marks each citation's link in `article`: a paragraph right after a
  // quote that holds nothing but a link to a channel's or a DM's page.
  function mark(article) {
    var after = article.querySelectorAll('.body blockquote + p');
    for (var i = 0; i < after.length; i++) {
      var only = after[i].childNodes.length === 1 ? after[i].firstChild : null;
      var href = only && only.nodeName === 'A' ? only.getAttribute('href') || '' : '';
      if (/^\/chat\/(channel|dm)\//.test(href)) after[i].classList.add('citation-link');
    }
  }

  window.Citation = { copy: copy, mark: mark };
})();
