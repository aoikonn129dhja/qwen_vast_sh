'use strict';
importScripts('core.js', 'download-service.js');

const service = XDownloadService.create(chrome, fetch, crypto);
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== 'xid:download') return;
  service.start(message.image, sender).then(
    result => sendResponse({ ok: true, ...result }),
    error => sendResponse({ ok: false, error: error.message })
  );
  return true;
});
chrome.downloads.onChanged.addListener(delta => {
  if (delta.state || delta.error) service.finish(delta.id).catch(error => console.error('Download status:', error.message));
});
