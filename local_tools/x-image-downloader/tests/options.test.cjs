'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const cssom = require('rrweb-cssom');
const root = path.join(__dirname, '..');
const tick = () => new Promise(resolve => setImmediate(resolve));

async function fixture(t, stored, failure = '') {
  const dom = new JSDOM(fs.readFileSync(path.join(root, 'options.html'), 'utf8'), { runScripts: 'outside-only' });
  t.after(() => dom.window.close());
  const writes = [];
  dom.window.chrome = { storage: { local: {
    async get() { if (failure === 'read') throw new Error('read failed'); return { downloadSettings: stored }; },
    async set(value) { if (failure === 'write') throw new Error('write failed'); writes.push(JSON.parse(JSON.stringify(value))); }
  } } };
  for (const file of ['core.js', 'options.js']) dom.window.eval(fs.readFileSync(path.join(root, file), 'utf8'));
  await tick();
  const document = dom.window.document;
  return { document, writes, submit() {
    document.querySelector('form').dispatchEvent(new dom.window.Event('submit', { cancelable: true }));
    return tick();
  } };
}

test('options loads existing values, saves normalized settings, and preserves other storage keys', async t => {
  const f = await fixture(t, { directory: 'X画像', saveAs: true });
  assert.equal(f.document.querySelector('#directory').value, 'X画像');
  assert.equal(f.document.querySelector('#save-as').checked, true);
  f.document.querySelector('#directory').value = ' X画像\\新規 ';
  f.document.querySelector('#save-as').checked = false;
  await f.submit();
  assert.deepEqual(f.writes, [{ downloadSettings: { directory: 'X画像/新規', saveAs: false } }]);
  assert.match(f.document.querySelector('#status').textContent, /保存しました/);
  assert.match(f.document.querySelector('#preview').textContent, /X画像\/新規\//);
});

test('blank directory restores the Chrome default destination', async t => {
  const f = await fixture(t);
  await f.submit();
  assert.deepEqual(f.writes, [{ downloadSettings: { directory: '', saveAs: false } }]);
});

test('invalid options do not overwrite saved settings', async t => {
  const f = await fixture(t, { directory: 'existing' });
  f.document.querySelector('#directory').value = 'C:\\images';
  await f.submit();
  assert.equal(f.writes.length, 0);
  assert.equal(f.document.querySelector('#status').dataset.error, 'true');
  assert.equal(f.document.querySelector('fieldset').disabled, false);
});

test('storage read and write failures are reported without claiming success', async t => {
  const read = await fixture(t, undefined, 'read');
  assert.equal(read.document.querySelector('fieldset').disabled, true);
  await read.submit();
  assert.equal(read.writes.length, 0);
  assert.match(read.document.querySelector('#status').textContent, /読み込めません/);
  const write = await fixture(t, undefined, 'write');
  await write.submit();
  assert.match(write.document.querySelector('#status').textContent, /保存できません/);
  assert.equal(write.document.querySelector('fieldset').disabled, false);
});

test('options HTML references local assets and its stylesheet parses', () => {
  const dom = new JSDOM(fs.readFileSync(path.join(root, 'options.html'), 'utf8'));
  try {
    for (const node of dom.window.document.querySelectorAll('script[src], link[href]')) {
      const file = node.getAttribute('src') || node.getAttribute('href');
      assert.ok(fs.existsSync(path.join(root, file)), file);
    }
    assert.ok(cssom.parse(fs.readFileSync(path.join(root, 'options.css'), 'utf8')).cssRules.length > 0);
    for (const label of dom.window.document.querySelectorAll('label[for]')) {
      assert.ok(dom.window.document.getElementById(label.htmlFor));
    }
  } finally { dom.window.close(); }
});
