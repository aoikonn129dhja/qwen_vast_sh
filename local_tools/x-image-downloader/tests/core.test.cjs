'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const core = require('../core.js');
const image = { account: 'ouran_sakura__', postId: '123', index: 1, url: 'https://pbs.twimg.com/media/Ab_-12?format=jpg&name=small' };

test('account cleanup removes only the trailing digits and underscores', () => {
  for (const [input, expected] of [
    ['@ouran_sakura__', 'ouran_sakura'], ['@kimiko9', 'kimiko'],
    ['abc_12__', 'abc'], ['abc9_name', 'abc9_name'], ['123___', 'account']
  ]) assert.equal(core.normalizeAccount(input), expected);
  for (const bad of ['../../evil', '', 'a'.repeat(16)]) assert.throws(() => core.normalizeAccount(bad));
});

test('original URL preserves format and media identity, discarding unrelated parameters', () => {
  assert.equal(core.originalUrl(image.url), 'https://pbs.twimg.com/media/Ab_-12?format=jpg&name=orig');
  assert.equal(core.originalUrl('https://pbs.twimg.com/media/Ab.png:large'), 'https://pbs.twimg.com/media/Ab?format=png&name=orig');
  assert.equal(core.originalUrl('https://pbs.twimg.com/media/Ab?format=webp&name=large&other=x'), 'https://pbs.twimg.com/media/Ab?format=webp&name=orig');
  for (const bad of [
    'http://pbs.twimg.com/media/a?format=jpg', 'https://evil.example/media/a?format=jpg',
    'https://pbs.twimg.com.evil.example/media/a?format=jpg', 'https://pbs.twimg.com/profile_images/a?format=jpg',
    'https://pbs.twimg.com/media/a?format=svg', 'https://pbs.twimg.com/media/a',
    'https://user:password@pbs.twimg.com/media/a?format=jpg'
  ]) assert.throws(() => core.originalUrl(bad));
});

test('image links identify the image owner, post, and 1-based index', () => {
  assert.deepEqual(core.parsePostLink('/kimiko9/status/123/photo/2'), { account: 'kimiko9', postId: '123', index: 2 });
  assert.equal(core.parsePostLink('https://twitter.com/a/status/9/photo/4').index, 4);
  for (const bad of ['/a/status/123/photo/5', '/i/status/123/analytics', '/a/photo', 'https://evil.example/a/status/123/photo/1']) {
    assert.equal(core.parsePostLink(bad), null);
  }
});

test('filename generation and MIME extension match the required pattern', () => {
  assert.equal(core.filename(image, 583, 'jpg'), 'ouran_sakura583 (1).jpg');
  assert.equal(core.filename({ ...image, account: 'kimiko9', index: 2 }, 100, 'png'), 'kimiko100 (2).png');
  assert.equal(core.extensionForMime('image/jpeg; charset=binary'), 'jpg');
  assert.equal(core.extensionForMime('text/html'), null);
  for (const bad of [99, 1000, NaN]) assert.throws(() => core.filename(image, bad, 'jpg'));
  for (const index of [0, 5, '1', 1.5]) assert.throws(() => core.validateRequest({ ...image, index }));
});

test('random integer covers endpoints and rejects the biased tail', () => {
  assert.equal(core.randomNumber({ getRandomValues: a => { a[0] = 0; } }), 100);
  assert.equal(core.randomNumber({ getRandomValues: a => { a[0] = 899; } }), 999);
  let calls = 0;
  assert.equal(core.randomNumber({ getRandomValues: a => { a[0] = calls++ ? 42 : 0xffffffff; } }), 142);
  assert.equal(calls, 2);
});

test('download directories accept relative nested folders and normalize Windows separators', () => {
  assert.deepEqual(core.downloadSettings(), { directory: '', saveAs: false });
  assert.deepEqual(core.downloadSettings({ directory: ' X画像\\お気に入り ', saveAs: true }),
    { directory: 'X画像/お気に入り', saveAs: true });
  for (const directory of ['C:\\images', '/images', '\\\\server\\images', '../images', 'a/../b',
    'a//b', 'a/', './images', 'a/CON.txt', 'aux', 'a/b.', 'a/ b', 'a?b', 'a\u0000b']) {
    assert.throws(() => core.downloadSettings({ directory }), undefined, directory);
  }
  for (const value of [null, [], { directory: 123 }, { saveAs: 'true' }]) {
    assert.throws(() => core.downloadSettings(value));
  }
});
