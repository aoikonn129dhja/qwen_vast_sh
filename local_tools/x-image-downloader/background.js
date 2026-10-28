'use strict';
importScripts('core.js', 'download-service.js', 'instagram-core.js', 'instagram-download-service.js');

const service = XDownloadService.create(chrome, fetch, crypto);
const instagramService = InstagramDownloadService.create(chrome, fetch, crypto);
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const selected = message?.type === 'xid:download' ? service :
    message?.type === 'iid:download' ? instagramService : null;
  if (!selected) return;
  selected.start(message.image, sender).then(
    result => sendResponse({ ok: true, ...result }),
    error => sendResponse({ ok: false, error: error.message })
  );
  return true;
});
chrome.downloads.onChanged.addListener(delta => {
  if (delta.state || delta.error) {
    service.finish(delta.id).catch(error => console.error('X download status:', error.message));
    instagramService.finish(delta.id).catch(error => console.error('Instagram download status:', error.message));
  }
});
