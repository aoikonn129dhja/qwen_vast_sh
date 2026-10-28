'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../instagram-core.js');
const { create } = require('../instagram-download-service.js');
const image = { account: 'ouran_sakura__', postId: 'De8mYVxm9lt', index: 1,
  url: 'https://scontent-nrt1-1.cdninstagram.com/v/t51.82787-15/123_n.jpg?stp=large' };
const sender = { id: 'extension-id', url: 'https://www.instagram.com/p/De8mYVxm9lt/', tab: { id: 7 } };
function storage() {
  const data = {};
  return { data, async get(key) { return { [key]: data[key] }; },
    async set(values) { Object.assign(data, values); }, async remove(key) { delete data[key]; } };
}
function fixture(failHead = false) {
  const downloads = [], messages = [], items = new Map();
  const api = { runtime: { id: 'extension-id' }, storage: { local: storage(), session: storage() },
    downloads: { async download(args) { downloads.push(args); const id = downloads.length;
      items.set(id, { id, state: 'in_progress', filename: args.filename }); return id; },
    async search({ id }) { return items.has(id) ? [items.get(id)] : []; } },
    tabs: { async sendMessage(tabId, message) { messages.push({ tabId, ...message }); } } };
  const fetcher = async () => ({ ok: !failHead, status: failHead ? 403 : 200,
    headers: new Headers({ 'content-type': 'image/jpeg' }) });
  const crypto = { getRandomValues: a => { a[0] = 483; } };
  return { api, downloads, messages, items, service: create(api, fetcher, crypto) };
}
test('all images in one post retain one number, never overwrite, and report completion', async () => {
  const f = fixture();
  const [first, second] = await Promise.all([f.service.start(image, sender),
    f.service.start({ ...image, index: 2 }, sender)]);
  assert.equal(first.filename, 'ouran_sakura583 (1).jpg');
  assert.equal(second.filename, first.filename);
  assert.deepEqual(f.downloads[0], { url: image.url, filename: first.filename, conflictAction: 'uniquify' });
  assert.equal(Object.keys(f.api.storage.local.data).length, 1);
  f.items.get(first.id).state = 'complete';
  await f.service.finish(first.id);
  assert.equal(f.messages[0].state, 'complete');
});
test('bad sender, bad media, and failed image HEAD do not download', async () => {
  const f = fixture();
  await assert.rejects(f.service.start(image, { ...sender, url: 'https://evil.example' }));
  await assert.rejects(f.service.start({ ...image, url: 'https://evil.example/v/x.jpg' }, sender));
  assert.equal(f.downloads.length, 0);
  const failed = fixture(true);
  await assert.rejects(failed.service.start(image, sender), /403/);
  assert.equal(failed.downloads.length, 0);
});
