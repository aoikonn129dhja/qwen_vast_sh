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
  assert.equal(core.filename({ ...image, account: 'kimiko9', index: 2 }, 100, 'png'), 'kimiko100 (1).png');
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

test('video poster URLs stay intact and use a separate save state', () => {
  const poster = 'https://pbs.twimg.com/amplify_video_thumb/123/img/Ab.jpg';
  const thumbnail = { ...image, kind: 'thumbnail', url: poster };
  assert.equal(core.validateRequest(thumbnail).url, poster);
  assert.equal(core.imageKey(thumbnail), 'ouran_sakura__:123:1:thumbnail');
  assert.equal(core.filename(thumbnail, 583, 'jpg'), 'ouran_sakura583 (1).jpg');
  assert.throws(() => core.thumbnailUrl('https://pbs.twimg.com/profile_images/Ab.jpg'));
});
