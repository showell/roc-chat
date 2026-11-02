// **UPLOADS FROM THE COMPOSE BOX, THE SCRIPT'S RULES, IN NODE** (js/upload.js),
// run by verify: with a stubbed page (the form, the box, the status line,
// the button, the file picker, XMLHttpRequest, Compose): the button opens
// the picker; a file picked, or an image pasted (and nothing else pasted),
// is sent as the form's one part `file` to the page's upload URL, the
// button off while it runs and a second one told to wait; its progress said
// by percent and megabytes, then "Saving"; the answer puts `<img src alt>`
// at the cursor, the name's quotes and brackets dropped; a refusal says the
// server's words (an HTML page or a long one, "Upload failed."), a dropped
// connection and the five minutes each their own; an image past the page's
// limit is said, never sent. The shrink's plan: a photo past 2048 px scaled
// to it, a big JPEG re-encoded, a PNG kept PNG, a GIF or WebP as it is. One
// line a check, PASS or FAIL, then exit 1 when any failed.
//
//   node tools/upload_test.js
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'js', 'upload.js'), 'utf8');

function element() {
  const el = {
    style: {}, dataset: {}, listeners: {}, textContent: '', disabled: false, clicked: 0, value: '',
    addEventListener(t, fn) { (el.listeners[t] = el.listeners[t] || []).push(fn); },
    click() { el.clicked++; },
  };
  return el;
}

function page() {
  const form = element();
  form.dataset = { upload: '/chat/channel/A/B/upload', imageMost: String(10 * 1048576) };
  const els = { 'chat-form': form, 'chat-body': element(), 'chat-status': element(), 'chat-upload-btn': element(), 'chat-file': element() };
  const sent = [];
  const inserted = [];
  function XMLHttpRequest() {
    const x = { upload: {}, sent: null, opened: null };
    x.open = (method, url) => { x.opened = { method, url }; };
    x.send = (body) => { x.sent = body; sent.push(x); };
    return x;
  }
  function FormData() { const parts = []; return { parts, append(k, v) { parts.push([k, v]); } }; }
  const ctx = {
    document: { getElementById: (id) => els[id] },
    window: {}, XMLHttpRequest, FormData, setTimeout, clearTimeout,
    Compose: { insertAtCursor: (t) => inserted.push(t) },
  };
  vm.createContext(ctx);
  vm.runInContext(source, ctx);
  const fire = (el, t, e) => {
    let prevented = false;
    const ev = Object.assign({ preventDefault() { prevented = true; } }, e || {});
    (el.listeners[t] || []).forEach((fn) => fn(ev));
    return prevented;
  };
  const pick = (file) => { els['chat-file'].files = [file]; fire(els['chat-file'], 'change'); };
  return { els, sent, inserted, fire, pick, status: () => els['chat-status'].textContent, button: els['chat-upload-btn'], plan: ctx.window.Upload.resizePlan };
}

// A GIF is sent as it is: no shrinking, so the send is at once.
const gif = (name, size) => ({ name, type: 'image/gif', size });

let failed = 0;
function check(ok, what) {
  console.log((ok ? 'PASS' : 'FAIL') + '  upload.js: ' + what);
  if (!ok) failed++;
}

{
  const p = page();
  p.fire(p.button, 'click');
  check(p.els['chat-file'].clicked === 1, 'the Upload button opens the file picker');
  p.pick(gif('cat.gif', 3 * 1048576));
  const x = p.sent[0];
  check(x && x.opened.method === 'POST' && x.opened.url === '/chat/channel/A/B/upload' && x.sent.parts.length === 1 && x.sent.parts[0][0] === 'file' && x.sent.parts[0][1].name === 'cat.gif', 'a file picked is sent to the page\'s upload URL as the one part `file`');
  check(p.button.disabled && p.status() === 'Uploading image: 0% of 3.0 MB…' && x.timeout === 5 * 60 * 1000, 'the button off, "Uploading image: 0% of 3.0 MB…", five minutes\' patience');
  x.upload.onprogress({ lengthComputable: true, loaded: 1048576, total: 3 * 1048576 });
  check(p.status() === 'Uploading image: 33% of 3.0 MB…', 'progress by percent and megabytes');
  x.upload.onprogress({ lengthComputable: true, loaded: 3 * 1048576, total: 3 * 1048576 });
  check(p.status() === 'Saving image…', 'all of it gone: "Saving image…"');
  p.pick(gif('dog.gif', 10));
  check(p.sent.length === 1 && p.status() === 'Still sending the last upload — one at a time, please.', 'a second upload while one runs is told to wait, and not sent');
  x.status = 200;
  x.responseText = '{"url":"/chat/uploads/a/b/x.gif","name":"c\\"a<t>.gif","kind":"image","width":0,"height":0}';
  x.onload();
  check(p.inserted[0] === '<img src="/chat/uploads/a/b/x.gif" alt="cat.gif">' && p.status() === '' && !p.button.disabled, 'the answer: <img src alt> at the cursor, the name\'s quotes and brackets dropped, no size, the button back');
}
{
  const p = page();
  p.pick(gif('a.gif', 1));
  const x = p.sent[0];
  x.status = 415;
  x.responseText = 'unsupported file type (images: png, jpeg, gif, webp)\n';
  x.onload();
  check(p.status() === 'unsupported file type (images: png, jpeg, gif, webp)' && p.inserted.length === 0 && !p.button.disabled, 'a refusal says the server\'s words, nothing put in');
  p.pick(gif('a.gif', 1));
  p.sent[1].status = 500;
  p.sent[1].responseText = '<html>oops</html>';
  p.sent[1].onload();
  check(p.status() === 'Upload failed.', 'an HTML answer: "Upload failed."');
  p.pick(gif('a.gif', 1));
  p.sent[2].onerror();
  check(p.status() === 'Upload failed: the connection dropped. Please try again.', 'a dropped connection says so');
  p.pick(gif('a.gif', 1));
  p.sent[3].ontimeout();
  check(p.status() === 'Upload gave up after 5 minutes. Please try again.', 'past the five minutes says so');
  p.pick(gif('a.gif', 1));
  p.sent[4].status = 200;
  p.sent[4].responseText = 'not json';
  p.sent[4].onload();
  check(p.status().indexOf('Upload failed: the answer did not read') === 0 && p.inserted.length === 0, 'an answer that is no JSON says so');
}
{
  const p = page();
  p.pick(gif('big.gif', 10 * 1048576 + 1));
  check(p.sent.length === 0 && p.status() === 'That image is 10.0 MB — too big to send (limit 10 MB). Try compressing or resizing it.' && !p.button.disabled, 'past the page\'s limit: said, never sent');
  p.pick(gif('edge.gif', 10 * 1048576));
  check(p.sent.length === 1, 'at the limit: sent');
}
{
  const p = page();
  const held = p.fire(p.els['chat-body'], 'paste', { clipboardData: { files: [{ name: 'notes.txt', type: 'text/plain', size: 5 }, gif('pasted.gif', 5)] } });
  check(held && p.sent.length === 1 && p.sent[0].sent.parts[0][1].name === 'pasted.gif', 'an image pasted is uploaded, the paste held back');
  const q = page();
  const kept = q.fire(q.els['chat-body'], 'paste', { clipboardData: { files: [{ name: 'notes.txt', type: 'text/plain', size: 5 }] } });
  const plain = q.fire(q.els['chat-body'], 'paste', { clipboardData: { files: [] } });
  check(!kept && !plain && q.sent.length === 0, 'anything else pasted is the box\'s');
}
{
  const plan = page().plan;
  const s = (v) => JSON.stringify(v);
  check(s(plan('image/png', 5e6, 4096, 1024)) === s({ width: 2048, height: 512, type: 'image/png' }), 'a PNG past 2048 px: scaled to it, kept PNG');
  check(s(plan('image/jpeg', 1e6, 1000, 3000)) === s({ width: 683, height: 2048, type: 'image/jpeg' }), 'a tall JPEG past 2048 px: its height to 2048');
  check(s(plan('image/jpeg', 2 * 1048576, 1000, 800)) === s({ width: 1000, height: 800, type: 'image/jpeg' }), 'a JPEG over 1.5 MB at its size: re-encoded');
  check(plan('image/jpeg', 1048576, 1000, 800) === null && plan('image/png', 9e6, 2048, 2048) === null, 'within both: sent as it is');
  check(plan('image/gif', 9e6, 4096, 4096) === null && plan('image/webp', 9e6, 4096, 4096) === null && plan('image/png', 1, 0, 0) === null, 'a GIF, a WebP, or no size: as it is');
}
process.exit(failed === 0 ? 0 : 1);
