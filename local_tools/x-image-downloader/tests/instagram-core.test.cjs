'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const core = require('../instagram-core.js');
const url = 'https://scontent-nrt1-1.cdninstagram.com/v/t51.82787-15/123_n.jpg?stp=large&oh=abc';
const image = { account: 'suiika_desuwa', postId: 'De8mYVxm9lt', index: 2, url };

test('post identity and account cleanup follow X naming rules', () => {
  assert.deepEqual(core.parsePostLink('/suiika_desuwa/p/De8mYVxm9lt/'), { account: 'suiika_desuwa', postId: 'De8mYVxm9lt', index: 1 });
  assert.equal(core.parsePostLink('https://www.instagram.com/p/De8mYVxm9lt/?img_index=2').index, 2);
  assert.equal(core.parsePostLink('https://evil.example/p/De8mYVxm9lt/'), null);
  assert.equal(core.normalizeAccount('@ouran_sakura__'), 'ouran_sakura');
  assert.equal(core.normalizeAccount('kimiko9'), 'kimiko');
  assert.equal(core.filename(image, 583, 'jpg'), 'suiika_desuwa583 (1).jpg');
});
test('largest declared image is used without changing its signed URL', () => {
  const img = { getAttribute: () => `${url} 1080w, ${url.replace('large', 'small')} 320w`, currentSrc: url, src: url };
  assert.equal(core.largestImageUrl(img), url);
  for (const bad of ['https://evil.example/v/123.jpg', 'http://scontent-nrt1-1.cdninstagram.com/v/123.jpg',
    'https://scontent-nrt1-1.cdninstagram.com/v/123.svg']) assert.throws(() => core.validateImageUrl(bad));
  assert.equal(core.extensionForMime('image/jpeg; charset=binary'), 'jpg');
  assert.equal(core.extensionForMime('text/html'), null);
});
test('image indexes and random range are validated', () => {
  for (const index of [0, 101, 1.5, '2']) assert.throws(() => core.validateRequest({ ...image, index }));
  assert.equal(core.randomNumber({ getRandomValues: a => { a[0] = 0; } }), 100);
  assert.equal(core.randomNumber({ getRandomValues: a => { a[0] = 899; } }), 999);
});
