// This script runs on a signed-out visitor's page: the sign-in page, the
// join page and the page where someone GitHub vouched for chooses a name,
// which app/SignInPage.roc and app/JoinPage.roc build and app/Script.roc
// serves.
//
// Each such page is a heading, a few lines and its forms, straight in the
// body. The script draws the body as a card, as panel.js draws a signed-in
// page's panel: at most 380 pixels wide, centred in the window (on a phone,
// the window's width less a 16-pixel gutter each side, near the top, where
// the keyboard leaves it seen). In a form, each label sits over its field,
// the fields one column of one width; the form's button is the primary
// action, in the accent as compose.js's Send, across the column, but for the
// device code's, which is quiet, as a popup's second button is. A second
// form sits under a rule. A problem (.problem) is drawn as panel.js draws
// one. A form the page hides (join.js's, for a used invite) stays hidden.
// Its colours are palette.js's.
(function () {
  'use strict';
  var rules = document.createElement('style');
  rules.textContent = [
    'html { min-height: 100%; display: flex; background: var(--cc-bg); }',
    'body { box-sizing: border-box; width: calc(100% - 32px); max-width: 380px; margin: auto; padding: 20px 24px;' +
      ' font-family: sans-serif; font-size: 14px; line-height: 1.4; background: var(--cc-card-bg);' +
      ' border: 1px solid var(--cc-border); border-radius: 8px; overflow-wrap: anywhere; }',
    'h1 { font-size: 20px; margin: 0 0 12px; }',
    'p { margin: 0 0 12px; }',
    'a { color: var(--cc-accent); }',
    'form { display: flex; flex-direction: column; gap: 12px; margin: 0; }',
    'form[hidden] { display: none; }',
    'form + form { border-top: 1px solid var(--cc-border); margin-top: 20px; padding-top: 16px; }',
    'form p { margin: 0; }',
    'form p, form label { display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: var(--cc-body-muted-fg); }',
    'input { box-sizing: border-box; width: 100%; font-family: inherit; font-size: 14px; padding: 7px 10px;' +
      ' background: var(--cc-bg); color: var(--cc-fg); border: 1px solid var(--cc-input-border); border-radius: 6px; }',
    'input:focus { outline: none; border-color: var(--cc-accent); box-shadow: 0 0 0 1px var(--cc-accent); }',
    'button { font-family: inherit; font-size: 14px; padding: 7px 14px; border-radius: 6px; cursor: pointer;' +
      ' background: var(--cc-accent); color: var(--cc-bg); border: 1px solid var(--cc-accent); }',
    'button:hover { background: var(--cc-accent-hover); border-color: var(--cc-accent-hover); }',
    'form[action="/login/code"] button { align-self: flex-start; font-size: 13px; padding: 5px 14px;' +
      ' background: none; color: var(--cc-fg); border-color: var(--cc-quote-border); }',
    'form[action="/login/code"] button:hover { background: var(--cc-accent-soft-hov); border-color: var(--cc-quote-border); }',
    'button:focus-visible, a:focus-visible { outline: 2px solid var(--cc-accent); outline-offset: 2px; }',
    '.problem { color: var(--cc-error); background: color-mix(in srgb, var(--cc-error) 12%, transparent);' +
      ' border: 1px solid color-mix(in srgb, var(--cc-error) 40%, transparent); border-radius: 6px; padding: 6px 10px; }',
    // A phone's: the card near the top, and 16-pixel fields, which a phone
    // does not zoom into.
    '@media (max-width: 600px) { body { margin: 16px auto auto; padding: 16px; } input { font-size: 16px; } }',
  ].join('\n');
  document.head.appendChild(rules);
})();
