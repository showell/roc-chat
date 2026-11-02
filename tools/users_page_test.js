// **THE USERS PAGE'S ARE-YOU-SURE, IN NODE** (js/users_page.js), run by
// verify: a Remove form asks first, naming who; declined, nothing is sent;
// accepted, the form goes; any other form is never asked about. One line a
// check, PASS or FAIL, then exit 1 when any failed.
//
//   node tools/users_page_test.js
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'js', 'users_page.js'), 'utf8');

function page(answer) {
  const asked = [];
  const listeners = {};
  const ctx = {
    document: { addEventListener: (t, fn) => { (listeners[t] = listeners[t] || []).push(fn); } },
    window: { confirm: (q) => { asked.push(q); return answer; } },
  };
  vm.createContext(ctx);
  vm.runInContext(source, ctx);
  const submit = (form) => {
    let prevented = false;
    (listeners.submit || []).forEach((fn) => fn({ target: form, preventDefault() { prevented = true; } }));
    return prevented;
  };
  return { asked, submit };
}
const form = (cls, name) => ({ classList: { contains: (c) => c === cls }, dataset: { name } });

let failed = 0;
function check(ok, what) {
  console.log((ok ? 'PASS' : 'FAIL') + '  users_page.js: ' + what);
  if (!ok) failed++;
}

{
  const p = page(false);
  const held = p.submit(form('erase', 'Alice'));
  check(held && p.asked.length === 1 && p.asked[0] === 'Remove Alice and everything of theirs? This cannot be undone.', 'declined: asked, naming who, and nothing sent');
}
{
  const p = page(true);
  const held = p.submit(form('erase', 'Bob'));
  check(!held && p.asked.length === 1 && p.asked[0].indexOf('Remove Bob ') === 0, 'accepted: the form goes');
}
{
  const p = page(false);
  const held = p.submit(form('other', 'x'));
  check(!held && p.asked.length === 0, 'another form: never asked about');
}
process.exit(failed === 0 ? 0 : 1);
