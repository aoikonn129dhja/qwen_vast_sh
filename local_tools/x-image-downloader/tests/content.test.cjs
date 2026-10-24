'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const core = fs.readFileSync(path.join(__dirname, '../core.js'), 'utf8');
const content = fs.readFileSync(path.join(__dirname, '../content.js'), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));
const waitScan = () => new Promise(resolve => setTimeout(resolve, 160));

function photo(account = 'ouran_sakura__', post = '123', index = 1, media = 'Ab') {
  return `<a href="/${account}/status/${post}/photo/${index}"><div data-testid="tweetPhoto" style="position:absolute"><img src="https://pbs.twimg.com/media/${media}?format=jpg&name=small"></div></a>`;
}
function fixture(html, url = 'https://x.com/profile') {
  // No resources option: jsdom never requests the synthetic images.
  const dom = new JSDOM(`<body>${html}</body>`, { url, runScripts: 'outside-only' });
  const requests = [], listeners = [];
  let reply = async () => ({ ok: true, id: 1, filename: 'test.jpg' });
  dom.window.chrome = { runtime: {
    async sendMessage(message) { requests.push(message); return reply(message); },
    onMessage: { addListener(listener) { listeners.push(listener); } }
  } };
  dom.window.eval(core);
  dom.window.eval(content);
  return { dom, window: dom.window, document: dom.window.document, requests,
    reply(fn) { reply = fn; }, receive(message) { listeners.forEach(fn => fn(message)); } };
}
function buttons(f) {
  return [...f.document.querySelectorAll('.xid-download-host')].map(host => host.shadowRoot.querySelector('button'));
}

test('adds one button per image and uses each image owner rather than profile name', async t => {
  const f = fixture(photo('kimiko9', '123', 2) + photo('other_user', '456', 1));
  t.after(() => f.window.close());
  assert.equal(buttons(f).length, 2);
  let parentClicks = 0;
  f.document.querySelector('a').addEventListener('click', () => parentClicks++);
  buttons(f)[0].click();
  await tick();
  assert.equal(parentClicks, 0);
  assert.equal(f.requests[0].image.account, 'kimiko9');
  assert.equal(f.requests[0].image.index, 2);
  assert.equal(buttons(f)[0].textContent, '保存中');
  f.receive({ type: 'xid:result', key: 'kimiko9:123:2', state: 'complete', filename: 'kimiko583 (2).jpg' });
  assert.equal(buttons(f)[0].textContent, '保存済み');
  assert.equal(buttons(f)[0].disabled, false);
  await waitScan();
  assert.equal(buttons(f).length, 2, 'observer must not duplicate its own buttons');
});

test('same image repeated in the timeline shares UI state and blocks concurrent clicks', async t => {
  const f = fixture(photo() + photo());
  t.after(() => f.window.close());
  let resolve;
  f.reply(() => new Promise(done => { resolve = done; }));
  buttons(f)[0].click();
  buttons(f)[1].click();
  assert.equal(f.requests.length, 1);
  assert.ok(buttons(f).every(button => button.disabled));
  resolve({ ok: true, filename: 'test.jpg' });
  await tick();
  assert.ok(buttons(f).every(button => button.textContent === '保存中'));
});

test('shows failures and allows retry; late start response cannot overwrite completion', async t => {
  const f = fixture(photo());
  t.after(() => f.window.close());
  f.reply(async () => ({ ok: false, error: '原寸画像がありません' }));
  buttons(f)[0].click();
  await tick();
  assert.equal(buttons(f)[0].textContent, '再試行');
  assert.equal(buttons(f)[0].title, '原寸画像がありません');
  f.reply(async message => {
    f.receive({ type: 'xid:result', key: message.image.key, state: 'complete', filename: 'test.jpg' });
    return { ok: true, filename: 'test.jpg' };
  });
  buttons(f)[0].click();
  await tick();
  assert.equal(buttons(f)[0].textContent, '保存済み');
});

test('handles newly inserted and recycled image nodes', async t => {
  const f = fixture(photo());
  t.after(() => f.window.close());
  f.document.body.insertAdjacentHTML('beforeend', photo('kimiko9', '456', 2, 'Cd'));
  await waitScan();
  assert.equal(buttons(f).length, 2);
  const anchor = f.document.querySelector('a');
  anchor.href = '/new_owner/status/999/photo/3';
  anchor.querySelector('img').src = 'https://pbs.twimg.com/media/New?format=png&name=small';
  await waitScan();
  anchor.querySelector('.xid-download-host').shadowRoot.querySelector('button').click();
  await tick();
  assert.equal(f.requests[0].image.account, 'new_owner');
  assert.equal(f.requests[0].image.index, 3);
  assert.match(f.requests[0].image.url, /New\?format=png&name=orig$/);
});

test('photo viewer gets ownership and index from its URL', async t => {
  const f = fixture('<div role="dialog"><div style="position:absolute"><img src="https://pbs.twimg.com/media/Ab?format=jpg&name=large"></div></div>', 'https://x.com/wizxcos/status/123/photo/2');
  t.after(() => f.window.close());
  assert.equal(buttons(f).length, 1);
  buttons(f)[0].click();
  await tick();
  assert.equal(f.requests[0].image.account, 'wizxcos');
  assert.equal(f.requests[0].image.index, 2);
});

test('does not add buttons to avatars, video posters, or arbitrary media without a post link', t => {
  const f = fixture('<img src="https://pbs.twimg.com/profile_images/Ab.jpg"><div style="position:relative"><img src="https://pbs.twimg.com/media/Ab?format=jpg&name=small"></div>');
  t.after(() => f.window.close());
  assert.equal(buttons(f).length, 0);
});
