// **THE PAGES IN A REAL BROWSER**, by hand, never in `test`: start
// the end to end held (`zig build e2e -- --hold`, which
// says its port and A's, B's and H's session cookies), then
//   node tools/browser_check.js <port> <conversation> <A's cookie> <B's cookie> <H's cookie>
// with Playwright on the NODE_PATH. B watches the conversation, A posts with
// Enter (Shift-Enter adds a line), and B's page must show it live. Then H,
// on the agents page, makes an agent, invites it and sees the code once,
// revokes the invite, and starts a conversation with the agent ticked.
const { chromium } = require('playwright');
const [port, conv, ann, bea, hal] = process.argv.slice(2);
const base = `http://127.0.0.1:${port}`;
(async () => {
  const browser = await chromium.launch();
  const as = async (cookie) => {
    const ctx = await browser.newContext({ extraHTTPHeaders: { cookie } });
    // The rig's server takes writes from its configured origin alone (the
    // Origin check), which a browser on 127.0.0.1 is not: its writes say
    // the origin the server is configured with, as on the real site.
    // (Fetched and fulfilled: a continued request loses its cookie.)
    await ctx.route('**/*', async (route) => {
      const req = route.request();
      if (req.method() === 'GET' || req.method() === 'HEAD') return route.continue();
      const response = await route.fetch({ headers: { ...req.headers(), cookie, origin: 'http://chat.test' } });
      return route.fulfill({ response });
    });
    const page = await ctx.newPage();
    page.on('pageerror', (e) => console.log('PAGE ERROR', e.message));
    page.on('response', (r) => { if (r.status() >= 400) console.log('HTTP', r.status(), r.request().method(), r.url()); });
    page.on('console', (m) => { if (m.type() === 'error') console.log('CONSOLE', m.text()); });
    return page;
  };
  const a = await as(ann), b = await as(bea);
  await b.goto(`${base}/chat/${conv}`);
  await a.goto(`${base}/chat/${conv}`);
  const before = await b.locator('#messages article').count();
  console.log('B sees', before, 'messages; title:', await b.title());
  await a.fill('textarea', 'from the **browser**\nsecond line');
  // Shift-Enter adds a line, Enter sends.
  await a.focus('textarea');
  await a.keyboard.press('Shift+Enter');
  await a.keyboard.type('third line');
  await a.keyboard.press('Enter');
  await b.waitForFunction((n) => document.querySelectorAll('#messages article').length > n, before, { timeout: 5000 });
  const last = b.locator('#messages article').last();
  console.log('B got live:', JSON.stringify(await last.innerHTML()));
  console.log('A textarea after send:', JSON.stringify(await a.inputValue('textarea')));
  console.log('A sees', await a.locator('#messages article').count(), 'messages (no duplicate of its own)');
  await b.reload();
  console.log('B after reload sees', await b.locator('#messages article').count());
  const list = await as(ann);
  await list.goto(`${base}/chat`);
  console.log('A list:', JSON.stringify(await list.locator('#conversations').innerHTML()));
  await list.fill('input[name=with]', 'human:1002');
  await list.click('button');
  await list.waitForURL(/\/chat\/\d+$/, { timeout: 5000 });
  console.log('started, now at', list.url());

  const h = await as(hal);
  await h.goto(`${base}/chat`);
  await h.click('a[href="/chat/agents"]');
  await h.waitForURL(/\/chat\/agents$/);
  await h.fill('#make input[name=name]', 'Helper');
  await Promise.all([h.waitForNavigation(), h.click('#make button')]);
  console.log('H agents:', JSON.stringify(await h.locator('#agents').innerText()));
  await h.click('button.invite');
  await h.waitForSelector('#code:not([hidden])');
  const code = await h.locator('#code-text').innerText();
  console.log('H code shown:', code.length, 'hex digits; for', await h.locator('#code-for').innerText());
  await h.reload();
  const shown = (await h.content()).includes(code);
  console.log('H after reload: code on the page?', shown, '; invites listed:', await h.locator('#invites li').count());
  await Promise.all([h.waitForNavigation(), h.click('#invites button.revoke')]);
  console.log('H after revoke: invites listed:', await h.locator('#invites li').count());
  await h.goto(`${base}/chat`);
  await h.check('input[name=agent]');
  await h.click('#start button');
  await h.waitForURL(/\/chat\/\d+$/, { timeout: 5000 });
  console.log('H started with its agent, title:', await h.title());
  if (shown || code.length !== 64) throw new Error('the code was not shown exactly once');
  await browser.close();
})().catch((e) => { console.log('FAILED', e.message); process.exit(1); });
