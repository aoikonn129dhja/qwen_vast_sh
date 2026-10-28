(() => {
  'use strict';
  const core = globalThis.InstagramImageDownloader;
  const hosts = new Map();
  const states = new Map();
  const styles = `:host { color-scheme: dark; }
    button { box-sizing: border-box; display: block; min-width: 66px; height: 54px;
      padding: 0 18px; border: 1px solid #fff; border-radius: 999px;
      background: #111; color: #fff; font: 600 19.5px/1 system-ui, sans-serif;
      cursor: pointer; white-space: nowrap; }
    button:hover { background: #333; }
    button:focus-visible { outline: 3px solid #fff; outline-offset: 3px; }
    button:disabled { cursor: wait; }
    button[data-state="error"] { border-style: dashed; }`;

  function descriptor(img) {
    try {
      const article = img.closest('article');
      if (!article) return null;
      // Only the media carousel contains full-size post images. Avatars live in other lists.
      const carousel = article.querySelector('ul');
      if (!carousel || !carousel.contains(img)) return null;
      const slide = img.closest('li');
      const slides = [...carousel.children].filter(node => node.tagName === 'LI' && node.querySelector('img'));
      const index = slides.indexOf(slide) + 1;
      if (index < 1) return null;
      const post = core.parsePostLink(location.href);
      if (!post) return null;
      const account = article.querySelector('header a[href^="/"]')?.getAttribute('href')?.match(/^\/([A-Za-z0-9._]+)\/?$/)?.[1] ||
        article.querySelector('a[href^="/"]')?.getAttribute('href')?.match(/^\/([A-Za-z0-9._]+)\/?$/)?.[1] || post.account;
      if (!account) return null;
      const image = { account, postId: post.postId, index, url: core.largestImageUrl(img) };
      return { ...image, key: core.imageKey(image) };
    } catch { return null; }
  }

  function render(record) {
    const state = states.get(record.image.key) || { state: 'idle' };
    const labels = { idle: 'DL', pending: '取得中', started: '保存中', complete: '保存済み', error: '再試行' };
    record.button.textContent = labels[state.state] || 'DL';
    record.button.dataset.state = state.state;
    record.button.disabled = ['pending', 'started'].includes(state.state);
    record.button.title = state.error || state.filename || '投稿画像を保存';
    record.button.setAttribute('aria-label', state.error || `${record.image.account}の画像${record.image.index}: ${labels[state.state]}`);
  }
  function update(key, value) {
    states.set(key, value);
    for (const record of hosts.values()) if (record.image.key === key) render(record);
  }
  async function download(record, event) {
    event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation();
    const image = descriptor(record.img);
    if (!image || image.key !== record.image.key) { schedule(); return; }
    if (['pending', 'started'].includes(states.get(image.key)?.state)) return;
    update(image.key, { state: 'pending' });
    try {
      const response = await chrome.runtime.sendMessage({ type: 'iid:download', image });
      if (!response?.ok) throw new Error(response?.error || '拡張機能を再読み込みし、ページを再読み込みしてください。');
      if (states.get(image.key)?.state === 'pending') update(image.key, { state: 'started', filename: response.filename });
    } catch (error) { update(image.key, { state: 'error', error: error.message }); }
  }

  function scan() {
    for (const [img, record] of hosts) {
      const image = img.isConnected ? descriptor(img) : null;
      if (!image || image.key !== record.image.key || image.url !== record.image.url || !record.host.isConnected) {
        record.host.remove(); hosts.delete(img);
      }
    }
    for (const img of document.querySelectorAll('article ul li img[src*="cdninstagram.com/v/"]')) {
      if (hosts.has(img)) continue;
      const image = descriptor(img);
      if (!image) continue;
      const parent = img.parentElement;
      if (!parent || getComputedStyle(parent).position === 'static') continue;
      const host = document.createElement('span');
      host.className = 'iid-download-host';
      const shadow = host.attachShadow({ mode: 'open' });
      const style = document.createElement('style'); style.textContent = styles;
      const button = document.createElement('button'); button.type = 'button';
      const record = { img, image, host, button };
      button.addEventListener('click', event => { void download(record, event); });
      for (const type of ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'dblclick']) {
        button.addEventListener(type, event => event.stopPropagation());
      }
      shadow.append(style, button); parent.append(host); hosts.set(img, record); render(record);
    }
  }
  let timer;
  function schedule() { clearTimeout(timer); timer = setTimeout(scan, 100); }
  chrome.runtime.onMessage.addListener(message => {
    if (message?.type === 'iid:result' && typeof message.key === 'string') update(message.key, message);
  });
  new MutationObserver(records => {
    if (records.some(record => !record.target.closest?.('.iid-download-host') &&
        (record.type === 'attributes' || [...record.addedNodes, ...record.removedNodes]
          .some(node => node.nodeType === 1 && !node.classList.contains('iid-download-host'))))) schedule();
  }).observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ['src', 'srcset', 'href'] });
  window.addEventListener('popstate', schedule);
  scan();
})();
