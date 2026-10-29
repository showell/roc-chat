// **THE PAGES IN A REAL BROWSER** (QUEUE 315), by hand, never in `test`: start
// the end to end held (`zig build e2e -- --hold`, which
// says its port and A's and B's session cookies), then
//   node tools/browser_check.js <port> <conversation> <A's cookie> <B's cookie>
// with Playwright on the NODE_PATH. B watches the conversation, A posts with
// Enter (Shift-Enter adds a line), and B's page must show it live.
const { chromium } = require('playwright');
const [port, conv, ann, bea] = process.argv.slice(2);
const base = `http://127.0.0.1:${port}`;
(async () => {
  const browser = await chromium.launch();
  const as = async (cookie) => {
    const ctx = await browser.newContext({ extraHTTPHeaders: { cookie } });
    const page = await ctx.newPage();
    page.on('pageerror', (e) => console.log('PAGE ERROR', e.message));
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
  await browser.close();
})().catch((e) => { console.log('FAILED', e.message); process.exit(1); });
