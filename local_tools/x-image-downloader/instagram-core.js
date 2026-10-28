(function (root) {
  'use strict';
  const FORMATS = new Set(['jpg', 'jpeg', 'png', 'webp']);

  function parsePostLink(value, base = 'https://www.instagram.com') {
    try {
      const url = new URL(value, base);
      if (url.protocol !== 'https:' || !['instagram.com', 'www.instagram.com'].includes(url.hostname)) return null;
      const match = url.pathname.match(/^\/(?:([A-Za-z0-9._]+)\/)?p\/([A-Za-z0-9_-]+)\/?$/);
      if (!match) return null;
      const index = Number(url.searchParams.get('img_index') || 1);
      if (!Number.isInteger(index) || index < 1 || index > 100) return null;
      return { account: match[1] || null, postId: match[2], index };
    } catch { return null; }
  }

  function normalizeAccount(value) {
    const account = String(value).replace(/^@/, '');
    if (!/^[A-Za-z0-9._]{1,30}$/.test(account)) throw new Error('投稿者IDが不正です。');
    return account.replace(/[0-9_]+$/, '') || 'account';
  }

  function validateImageUrl(value) {
    const url = new URL(value);
    if (url.protocol !== 'https:' || !/^[a-z0-9-]+\.cdninstagram\.com$/i.test(url.hostname) ||
        url.username || url.password || url.port || !/^\/v\/[^?#]+\.(?:jpe?g|png|webp)$/i.test(url.pathname)) {
      throw new Error('画像URLが不正です。');
    }
    return url.href;
  }

  function largestImageUrl(img) {
    const candidates = (img.getAttribute('srcset') || '').split(',').map(part => {
      const match = part.trim().match(/^(https:\/\/\S+)\s+(\d+)w$/);
      return match ? { url: match[1], width: Number(match[2]) } : null;
    }).filter(Boolean).sort((a, b) => b.width - a.width);
    return validateImageUrl(candidates[0]?.url || img.currentSrc || img.src);
  }

  function validateRequest(input) {
    if (!input || typeof input.account !== 'string' || !/^[A-Za-z0-9._]{1,30}$/.test(input.account) ||
        typeof input.postId !== 'string' || !/^[A-Za-z0-9_-]{1,30}$/.test(input.postId) ||
        !Number.isInteger(input.index) || input.index < 1 || input.index > 100) {
      throw new Error('保存対象の情報が不正です。');
    }
    return { account: input.account, postId: input.postId, index: input.index, url: validateImageUrl(input.url) };
  }

  function imageKey(input) { return `${input.account.toLowerCase()}:${input.postId}:${input.index}`; }
  function randomNumber(cryptoApi = root.crypto) {
    const values = new Uint32Array(1);
    const limit = Math.floor(0x100000000 / 900) * 900;
    do { cryptoApi.getRandomValues(values); } while (values[0] >= limit);
    return 100 + values[0] % 900;
  }
  function filename(input, number, extension) {
    validateRequest(input);
    if (!Number.isInteger(number) || number < 100 || number > 999 || !FORMATS.has(extension)) throw new Error('保存名が不正です。');
    return `${normalizeAccount(input.account)}${number} (1).${extension === 'jpeg' ? 'jpg' : extension}`;
  }
  function extensionForMime(value) {
    return ({ 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' })[
      String(value).split(';')[0].trim().toLowerCase()
    ] || null;
  }
  const api = { parsePostLink, normalizeAccount, validateImageUrl, largestImageUrl, validateRequest,
    imageKey, randomNumber, filename, extensionForMime };
  root.InstagramImageDownloader = api;
  if (typeof module !== 'undefined') module.exports = api;
})(globalThis);
