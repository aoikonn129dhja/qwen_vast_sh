'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const cssom = require('rrweb-cssom');
const root = path.join(__dirname, '..');

test('manifest and package JSON are valid and all runtime files exist', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));
  JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  JSON.parse(fs.readFileSync(path.join(root, 'package-lock.json'), 'utf8'));
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.options_ui, undefined);
  assert.equal(manifest.action, undefined);
  const files = [manifest.background.service_worker,
    ...manifest.content_scripts.flatMap(entry => [...entry.js, ...entry.css]),
    'core.js', 'download-service.js', 'instagram-core.js', 'instagram-download-service.js'];
  for (const file of files) assert.ok(fs.existsSync(path.join(root, file)), file);
  assert.deepEqual(manifest.permissions, ['downloads', 'storage']);
  assert.deepEqual(manifest.host_permissions, ['https://pbs.twimg.com/*', 'https://*.cdninstagram.com/*']);
  assert.deepEqual(manifest.content_scripts.map(entry => entry.matches), [
    ['https://x.com/*', 'https://twitter.com/*'],
    ['https://www.instagram.com/*', 'https://instagram.com/*']
  ]);
});

test('Instagram overlay stylesheet parses with the same button dimensions', () => {
  const css = fs.readFileSync(path.join(root, 'instagram-content.css'), 'utf8');
  const sheet = cssom.parse(css);
  assert.equal(sheet.cssRules[0].selectorText, '.iid-download-host');
  assert.equal(sheet.cssRules[0].style.height, '54px');
  const source = fs.readFileSync(path.join(root, 'instagram-content.js'), 'utf8');
  const buttonCss = source.match(/const styles = `([\s\S]*?)`;/)[1];
  const buttonRule = cssom.parse(buttonCss).cssRules.find(rule => rule.selectorText === 'button');
  assert.equal(buttonRule.style['min-width'], '66px');
  assert.equal(buttonRule.style.height, '54px');
});

test('overlay stylesheet parses and does not hide or resize X images', () => {
  const css = fs.readFileSync(path.join(root, 'content.css'), 'utf8');
  const sheet = cssom.parse(css);
  assert.equal(sheet.cssRules.length, 1);
  assert.equal(sheet.cssRules[0].selectorText, '.xid-download-host');
  const source = fs.readFileSync(path.join(root, 'content.js'), 'utf8');
  const buttonCss = source.match(/const styles = `([\s\S]*?)`;/)[1];
  assert.ok(cssom.parse(buttonCss).cssRules.length >= 6);
  assert.ok(!css.includes('url('), 'overlay has no external asset dependencies');
  assert.equal(sheet.cssRules[0].style.top, '8px');
  assert.equal(sheet.cssRules[0].style.bottom, undefined);
  assert.equal(sheet.cssRules[0].style.height, '54px');
  const buttonRule = cssom.parse(buttonCss).cssRules.find(rule => rule.selectorText === 'button');
  assert.equal(buttonRule.style['min-width'], '66px');
  assert.equal(buttonRule.style.height, '54px');
});
