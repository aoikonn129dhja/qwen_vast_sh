'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../core.js');
const { create } = require('../download-service.js');
const image = { account: 'ouran_sakura__', postId: '123', index: 1, url: 'https://pbs.twimg.com/media/Ab?format=jpg&name=small' };
const sender = { id: 'extension-id', url: 'https://x.com/ouran_sakura__', tab: { id: 7 } };

function storage() {
  const data = {};
  return {
    data,
    async get(key) { return { [key]: data[key] }; },
    async set(values) { Object.assign(data, values); },
    async remove(key) { delete data[key]; }
  };
}
function fixture(options = {}) {
  const requests = [], downloads = [], messages = [], items = new Map();
  const api = {
    runtime: { id: 'extension-id' }, storage: { local: storage(), session: storage() },
    downloads: {
      async download(args) {
        if (options.failDownload) throw new Error('USER_CANCELED');
        downloads.push(args);
        const id = downloads.length;
        items.set(id, { id, state: options.instant ? 'complete' : 'in_progress', filename: args.filename });
        return id;
      },
      async search({ id }) { return items.has(id) ? [items.get(id)] : []; }
    },
    tabs: { async sendMessage(tabId, value) { messages.push({ tabId, ...value }); } }
  };
  const fetcher = async (url, init) => {
    requests.push({ url, init });
    return { ok: !options.failHead, status: options.failHead ? 404 : 200,
      headers: new Headers({ 'content-type': options.mime || 'image/jpeg' }) };
  };
  const crypto = { getRandomValues: a => { a[0] = 483; return a; } };
  return { api, requests, downloads, messages, items, fetcher, crypto, service: create(api, fetcher, crypto) };
}

test('original endpoint is checked and download uses explicit name without overwrite', async () => {
  const f = fixture();
  const result = await f.service.start(image, sender);
  assert.equal(result.filename, 'ouran_sakura583 (1).jpg');
  assert.equal(f.requests[0].init.method, 'HEAD');
  assert.equal(f.requests[0].init.credentials, 'omit');
  assert.match(f.requests[0].url, /name=orig$/);
  assert.deepEqual(f.downloads[0], { url: f.requests[0].url, filename: result.filename, conflictAction: 'uniquify' });
  assert.equal(f.messages.length, 0, 'must not report complete while still in progress');
  f.items.get(result.id).state = 'complete';
  await f.service.finish(result.id);
  assert.equal(f.messages[0].state, 'complete');
  assert.equal(f.messages[0].tabId, 7);
  assert.deepEqual(f.api.storage.session.data, {});
});

test('all images in a post share the persisted number, including after worker restart', async () => {
  const f = fixture();
  await Promise.all([f.service.start(image, sender), f.service.start({ ...image, index: 2 }, sender)]);
  assert.equal(Object.keys(f.api.storage.local.data).length, 1);
  const restarted = create(f.api, f.fetcher, { getRandomValues: a => { a[0] = 0; } });
  const result = await restarted.start({ ...image, index: 3 }, sender);
  assert.equal(result.filename, 'ouran_sakura583 (3).jpg');
});

test('failed original endpoint or non-image response never falls back to a thumbnail', async () => {
  for (const options of [{ failHead: true }, { mime: 'text/html' }]) {
    const f = fixture(options);
    await assert.rejects(f.service.start(image, sender));
    assert.equal(f.downloads.length, 0);
    assert.equal(f.requests.length, 1);
  }
});

test('extension follows the actual MIME extension', async () => {
  const f = fixture({ mime: 'image/png' });
  assert.match((await f.service.start(image, sender)).filename, /\.png$/);
});

test('fast completion before pending metadata is saved is still reported', async () => {
  const f = fixture({ instant: true });
  await f.service.start(image, sender);
  assert.equal(f.messages[0].state, 'complete');
  assert.deepEqual(f.api.storage.session.data, {});
});

test('worker restart retains pending download status and reports interruptions', async () => {
  const f = fixture();
  const { id } = await f.service.start(image, sender);
  f.items.get(id).state = 'interrupted';
  f.items.get(id).error = 'NETWORK_FAILED';
  const restarted = create(f.api, f.fetcher, f.crypto);
  await restarted.finish(id);
  assert.equal(f.messages[0].state, 'error');
  assert.match(f.messages[0].error, /NETWORK_FAILED/);
});

test('untrusted senders and invalid URLs cannot initiate a download', async () => {
  const f = fixture();
  for (const bad of [{ ...sender, id: 'other' }, { ...sender, url: 'https://evil.example' }, { ...sender, tab: {} }]) {
    await assert.rejects(f.service.start(image, bad));
  }
  await assert.rejects(f.service.start({ ...image, url: 'https://evil.example/payload' }, sender));
  assert.equal(f.requests.length, 0);
});

test('download initiation failure propagates without recording a completed save', async () => {
  const f = fixture({ failDownload: true });
  await assert.rejects(f.service.start(image, sender), /USER_CANCELED/);
  assert.equal(f.messages.length, 0);
  assert.deepEqual(f.api.storage.session.data, {});
});

test('old destination settings are ignored and Chrome controls the destination and save dialog', async () => {
  const f = fixture();
  for (const old of [{ directory: 'old-folder', saveAs: true }, { directory: 'D:\\po\\NSFW_cos', saveAs: false }, null]) {
    await f.api.storage.local.set({ downloadSettings: old });
    const result = await f.service.start(image, sender);
    const download = f.downloads.at(-1);
    assert.equal(download.filename, 'ouran_sakura583 (1).jpg');
    assert.equal(Object.hasOwn(download, 'saveAs'), false);
    assert.equal(download.conflictAction, 'uniquify');
    assert.equal(result.filename, download.filename);
  }
});
