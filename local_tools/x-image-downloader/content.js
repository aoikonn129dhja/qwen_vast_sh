(() => {
  'use strict';
  const core = globalThis.XImageDownloader;
  const hosts = new Map();
  const states = new Map();
  const styles = `
    :host { color-scheme: dark; }
    button { box-sizing: border-box; display: block; min-width: 66px; height: 54px;
      padding: 0 18px; border: 1px solid #fff; border-radius: 999px;
      background: #111; color: #fff; font: 600 19.5px/1 system-ui, sans-serif;
      cursor: pointer; white-space: nowrap; }
    button:hover { background: #333; }
    button:focus-visible { outline: 3px solid #fff; outline-offset: 3px; }
    button:disabled { cursor: wait; }
    button[data-state="error"] { border-style: dashed; }
  `;

  function descriptor(media) {
    try {
      if (media instanceof HTMLVideoElement) {
        const postLink = media.closest('article')?.querySelector('time')?.closest('a[href*="/status/"]');
        const post = postLink && core.parsePostLink(postLink.href);
        if (!post) return null;
        const image = { ...post, kind: 'thumbnail', url: core.thumbnailUrl(media.poster) };
        return { ...image, key: core.imageKey(image) };
      }
      const img = media;
      const raw = img.currentSrc || img.src;
      const url = core.originalUrl(raw);
      const anchor = img.closest('a[href*="/photo/"]');
      const post = anchor ? core.parsePostLink(anchor.href) :
        img.closest('[role="dialog"]') ? core.parsePostLink(location.href) : null;
      if (!post) return null;
      const image = { ...post, url };
      return { ...image, key: core.imageKey(image) };
    } catch { return null; }
  }

  function render(record) {
    const state = states.get(record.image.key) || { state: 'idle' };
    const labels = { idle: 'DL', pending: '取得中', started: '保存中', complete: '保存済み', error: '再試行' };
    record.button.textContent = labels[state.state] || 'DL';
    record.button.dataset.state = state.state;
    record.button.disabled = ['pending', 'started'].includes(state.state);
    record.button.title = state.error || state.filename || (record.image.kind === 'thumbnail' ? '動画サムネイルを保存' : '原寸画像を保存');
    record.button.setAttribute('aria-label', state.error || `${record.image.account}の${record.image.kind === 'thumbnail' ? '動画サムネイル' : `画像${record.image.index}`}: ${labels[state.state]}`);
  }

  function update(key, value) {
    states.set(key, value);
    for (const record of hosts.values()) if (record.image.key === key) render(record);
  }

  async function download(record, event) {
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    const image = descriptor(record.media);
    if (!image || image.key !== record.image.key) { schedule(); return; }
    if (['pending', 'started'].includes(states.get(image.key)?.state)) return;
    update(image.key, { state: 'pending' });
    try {
      const response = await chrome.runtime.sendMessage({ type: 'xid:download', image });
      if (!response?.ok) throw new Error(response?.error || '拡張機能を再読み込み後、Xも再読み込みしてください。');
      // A small download can finish before the start response arrives.
      if (states.get(image.key)?.state === 'pending') update(image.key, { state: 'started', filename: response.filename });
    } catch (error) { update(image.key, { state: 'error', error: error.message }); }
  }

  function scan() {
    for (const [media, record] of hosts) {
      const image = media.isConnected ? descriptor(media) : null;
      if (!image || image.key !== record.image.key || image.url !== record.image.url || !record.host.isConnected) {
        record.host.remove();
        hosts.delete(media);
      }
    }
    for (const media of document.querySelectorAll('img[src*="pbs.twimg.com/media/"], video[poster*="pbs.twimg.com/"]')) {
      if (hosts.has(media)) continue;
      const image = descriptor(media);
      if (!image) continue;
      const parent = media.parentElement;
      // X uses positioned media containers in both timeline and photo viewer.
      // Avoid changing X's layout if a future DOM revision removes this anchor.
      if (!parent || getComputedStyle(parent).position === 'static') continue;
      const host = document.createElement('span');
      host.className = 'xid-download-host';
      const shadow = host.attachShadow({ mode: 'open' });
      const style = document.createElement('style');
      style.textContent = styles;
      const button = document.createElement('button');
      button.type = 'button';
      const record = { media, image, host, button };
      button.addEventListener('click', event => { void download(record, event); });
      // Pointer events must not trigger X's parent image handlers.
      for (const type of ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'dblclick']) {
        button.addEventListener(type, event => event.stopPropagation());
      }
      shadow.append(style, button);
      parent.append(host);
      hosts.set(media, record);
      render(record);
    }
  }

  let timer;
  function schedule() {
    clearTimeout(timer);
    timer = setTimeout(scan, 100);
  }
  chrome.runtime.onMessage.addListener(message => {
    if (message?.type === 'xid:result' && typeof message.key === 'string') update(message.key, message);
  });
  new MutationObserver(records => {
    if (records.some(record => !record.target.closest?.('.xid-download-host') &&
        (record.type === 'attributes' || [...record.addedNodes, ...record.removedNodes]
          .some(node => node.nodeType === 1 && !node.classList.contains('xid-download-host'))))) schedule();
  }).observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ['src', 'poster', 'href'] });
  window.addEventListener('popstate', schedule);
  document.addEventListener('load', event => {
    if (event.target instanceof HTMLImageElement && event.target.src.includes('pbs.twimg.com/media/')) schedule();
  }, true);
  scan();
})();
