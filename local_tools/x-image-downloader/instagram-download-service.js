(function (root) {
  'use strict';
  const core = root.InstagramImageDownloader;
  function create(api, fetcher, cryptoApi) {
    let assignments = Promise.resolve();
    function numberFor(image) {
      const job = assignments.then(async () => {
        const key = `instagram:number:${image.account.toLowerCase()}:${image.postId}`;
        const stored = (await api.storage.local.get(key))[key];
        if (Number.isInteger(stored) && stored >= 100 && stored <= 999) return stored;
        const value = core.randomNumber(cryptoApi);
        await api.storage.local.set({ [key]: value });
        return value;
      });
      assignments = job.catch(() => {});
      return job;
    }
    async function finish(id) {
      const pendingKey = `instagram:pending:${id}`;
      const pending = (await api.storage.session.get(pendingKey))[pendingKey];
      if (!pending) return;
      const [item] = await api.downloads.search({ id });
      if (!item || !['complete', 'interrupted'].includes(item.state)) return;
      await api.storage.session.remove(pendingKey);
      try {
        await api.tabs.sendMessage(pending.tabId, {
          type: 'iid:result', key: pending.key,
          state: item.state === 'complete' ? 'complete' : 'error',
          filename: item.filename,
          error: item.state === 'interrupted' ? `保存できませんでした (${item.error || 'interrupted'})。再試行してください。` : undefined
        });
      } catch { /* The originating tab may have closed. */ }
    }
    async function run(image, tabId) {
      const key = core.imageKey(image);
      const response = await fetcher(image.url, {
        method: 'HEAD', credentials: 'omit', redirect: 'error', signal: AbortSignal.timeout(20000)
      });
      if (!response.ok) throw new Error(`画像を取得できません (HTTP ${response.status})。`);
      const extension = core.extensionForMime(response.headers.get('content-type'));
      if (!extension) throw new Error('画像URLが画像を返しませんでした。');
      const number = await numberFor(image);
      const name = core.filename(image, number, extension);
      const id = await api.downloads.download({ url: image.url, filename: name, conflictAction: 'uniquify' });
      await api.storage.session.set({ [`instagram:pending:${id}`]: { tabId, key } });
      await finish(id);
      return { id, key, filename: name };
    }
    async function start(input, sender) {
      const source = new URL(sender.url || 'about:blank');
      if (sender.id !== api.runtime.id || !Number.isInteger(sender.tab?.id) ||
          source.protocol !== 'https:' || !['instagram.com', 'www.instagram.com'].includes(source.hostname)) {
        throw new Error('Instagramのページからのみ保存できます。');
      }
      return run(core.validateRequest(input), sender.tab.id);
    }
    return { start, finish };
  }
  root.InstagramDownloadService = { create };
  if (typeof module !== 'undefined') module.exports = { create };
})(globalThis);
