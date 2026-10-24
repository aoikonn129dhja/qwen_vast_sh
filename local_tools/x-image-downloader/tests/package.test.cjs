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
  const files = [manifest.background.service_worker,
    ...manifest.content_scripts.flatMap(entry => [...entry.js, ...entry.css]),
    'core.js', 'download-service.js'];
  for (const file of files) assert.ok(fs.existsSync(path.join(root, file)), file);
  assert.deepEqual(manifest.permissions, ['downloads', 'storage']);
  assert.deepEqual(manifest.host_permissions, ['https://pbs.twimg.com/*']);
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
});
