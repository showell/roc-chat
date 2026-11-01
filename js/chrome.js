/* chrome.js: the browser client's frame, styled (app/Chrome.roc draws it).

   The server sends structure and class names, never style (Steve: "We
   should generally directly modify styles on the DOM. We want fairly
   minimal styling and as little bitrot as possible."). The frame's markup
   is the server's, so its rules go in one <style> this script adds, as
   chat-client's js/message.js does for the bubbles: the old chrome's top
   bar (angry-gopher's top_bar.zig, with its fallback colours, the colour
   tokens coming with the transcript's styling), the content column, a
   chat page's height, and Browse's lists; feed.js styles the transcript. Deleting this file deletes the frame's styling. */
(function () {
  'use strict';
  var s = document.createElement('style');
  s.textContent = ''
    + 'body { font-family: sans-serif; margin: 0; padding: 0; display: flex; flex-direction: column; min-height: 100vh; }'
    + '.app-body-wrap { flex: 1; max-width: 820px; margin: 32px auto; padding: 0 24px 60px; width: 100%; box-sizing: border-box; }'
    + '.app-top { background: var(--cc-top-bar-bg, #f0ede4); border-bottom: 1px solid var(--cc-top-bar-border, #c9bfa7); padding: 8px 24px; font-family: sans-serif; display: flex; justify-content: space-between; align-items: baseline; position: sticky; top: 0; z-index: 10; }'
    + '.app-top-user { font-size: 13px; color: var(--cc-body-muted-fg, #444); }'
    + '.app-top-user a { color: var(--cc-accent, #000080); }'
    + '.chat-top .chat-top-left { display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap; min-width: 0; }'
    + '.chat-top-home { color: var(--cc-accent, #000080); text-decoration: none; font-size: 13px; }'
    + '.chat-top-home:hover { text-decoration: underline; }'
    + '.chat-top-title { font-weight: bold; color: var(--cc-accent, #000080); }'
    + '.chat-top-links { font-size: 13px; }'
    + '.chat-top-links a { color: var(--cc-accent, #000080); text-decoration: none; }'
    + '.chat-top-links a:hover { text-decoration: underline; }'
    + 'form.logout { display: inline; }'
    + 'form.logout button { font: inherit; color: var(--cc-accent, #000080); background: none; border: none; padding: 0; cursor: pointer; text-decoration: underline; }'
    + 'h1 { color: var(--cc-accent, #000080); }'
    + 'a { color: var(--cc-accent, #000080); }'
    + '.muted { color: var(--cc-muted-fg, #888); }'
    + 'html:has(body.chat-page), body.chat-page { height: 100%; }'
    + '.chat-page .app-body-wrap { margin: 10px auto; padding: 0 24px 10px; min-height: 0; max-width: none; display: flex; flex-direction: column; }'
    + '.browse-list { list-style: none; padding: 0; margin: 0 0 18px; font-size: 13px; }'
    + '.browse-list li a { display: block; padding: 4px 8px; border-radius: 3px; text-decoration: none; }'
    + '.browse-list li.muted { padding: 4px 8px; font-style: italic; }'
    + '.browse h2 { font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; color: var(--cc-muted-fg, #888); margin: 0 0 6px; }';
  document.head.appendChild(s);
})();
