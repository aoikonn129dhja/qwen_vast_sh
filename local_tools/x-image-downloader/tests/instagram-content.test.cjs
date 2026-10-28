'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const core = fs.readFileSync(path.join(__dirname, '../instagram-core.js'), 'utf8');
const content = fs.readFileSync(path.join(__dirname, '../instagram-content.js'), 'utf8');
const url = n => `https://scontent-nrt1-1.cdninstagram.com/v/t51.82787-15/${n}_n.jpg?stp=large`;

test('post carousel and profile grid receive buttons while avatars are excluded', async t => {
  const html = `<a href="/other/p/Else/"><img src="${url(3)}"></a><article>
    <ul><li><div style="position:relative"><img src="${url(1)}" srcset="${url(1)} 1080w, ${url(2)} 320w"></div></li>
    <li><div style="position:relative"><img src="${url(2)}"></div></li></ul>
    <header><a href="/suiika_desuwa/">suiika_desuwa</a></header>
    <ul><li><img src="${url(4)}" alt="avatar"></li></ul></article>`;
  const dom = new JSDOM(`<body>${html}</body>`, { url: 'https://www.instagram.com/p/De8mYVxm9lt/?img_index=2', runScripts: 'outside-only' });
  t.after(() => dom.window.close());
  const requests = [];
  dom.window.chrome = { runtime: { sendMessage: async msg => { requests.push(msg); return { ok: true, filename: 'test.jpg' }; },
    onMessage: { addListener() {} } } };
  dom.window.eval(core); dom.window.eval(content);
  const buttons = [...dom.window.document.querySelectorAll('.iid-download-host')].map(host => host.shadowRoot.querySelector('button'));
  assert.equal(buttons.length, 3);
  buttons[2].click();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(requests[0].image.account, 'suiika_desuwa');
  assert.equal(requests[0].image.index, 2);
  assert.equal(buttons[2].textContent, '保存中');
  buttons[0].click();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(requests[1].image.account, 'other');
  assert.equal(requests[1].image.postId, 'Else');
  assert.equal(requests[1].image.index, 1);
});
