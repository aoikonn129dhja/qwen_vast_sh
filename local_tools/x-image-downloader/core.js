(function (root) {
  'use strict';
  const X_HOSTS = new Set(['x.com', 'twitter.com']);
  const FORMATS = new Set(['jpg', 'jpeg', 'png', 'webp']);

  function parsePostLink(value, base = 'https://x.com') {
    try {
      const url = new URL(value, base);
      if (url.protocol !== 'https:' || !X_HOSTS.has(url.hostname)) return null;
      const match = url.pathname.match(/^\/([A-Za-z0-9_]{1,15})\/status\/(\d+)(?:\/photo\/([1-4]))?\/?$/);
      if (!match) return null;
      return { account: match[1], postId: match[2], index: Number(match[3] || 1) };
    } catch { return null; }
  }

  function normalizeAccount(value) {
    const account = String(value).replace(/^@/, '');
    if (!/^[A-Za-z0-9_]{1,15}$/.test(account)) throw new Error('投稿者IDが不正です。');
    // Handles made entirely of digits/underscores still need a usable basename.
    return account.replace(/[0-9_]+$/, '') || 'account';
  }

  function originalUrl(value) {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.hostname !== 'pbs.twimg.com' ||
        url.username || url.password || url.port) throw new Error('画像URLが不正です。');
    const match = url.pathname.match(/^\/media\/([A-Za-z0-9_-]+)(?:\.(jpg|jpeg|png|webp)(?::[A-Za-z0-9]+)?)?$/i);
    const format = (url.searchParams.get('format') || match?.[2] || '').toLowerCase();
    if (!match || !FORMATS.has(format)) throw new Error('対応していない画像形式です。');
    return `https://pbs.twimg.com/media/${match[1]}?format=${format}&name=orig`;
  }

  function validateRequest(input) {
    if (!input || typeof input.account !== 'string' || !/^[A-Za-z0-9_]{1,15}$/.test(input.account) ||
        typeof input.postId !== 'string' || !/^\d{1,30}$/.test(input.postId) ||
        !Number.isInteger(input.index) || input.index < 1 || input.index > 4) {
      throw new Error('保存対象の情報が不正です。');
    }
    return { account: input.account, postId: input.postId, index: input.index, url: originalUrl(input.url) };
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
    if (!Number.isInteger(number) || number < 100 || number > 999 || !FORMATS.has(extension)) {
      throw new Error('保存名の情報が不正です。');
    }
    return `${normalizeAccount(input.account)}${number} (${input.index}).${extension === 'jpeg' ? 'jpg' : extension}`;
  }

  function extensionForMime(value) {
    return ({ 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' })[
      String(value).split(';')[0].trim().toLowerCase()
    ] || null;
  }

  function downloadSettings(value = {}) {
    if (!value || typeof value !== 'object' || Array.isArray(value) ||
        (value.directory !== undefined && typeof value.directory !== 'string') ||
        (value.saveAs !== undefined && typeof value.saveAs !== 'boolean')) {
      throw new Error('保存先の設定が不正です。設定画面で保存し直してください。');
    }
    const directory = (value.directory || '').trim().replace(/\\/g, '/');
    if (directory && (directory.length > 180 || directory.split('/').some(part =>
      !part || part === '.' || part === '..' || /^[. ]|[. ]$/.test(part) ||
      /[<>:"|?*\u0000-\u001f\u007f]/.test(part) ||
      /^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)/i.test(part)))) {
      throw new Error('Chromeのダウンロード先からの相対フォルダ名を入力してください。絶対パスや「..」、使用できない文字は指定できません。');
    }
    return { directory, saveAs: value.saveAs === true };
  }

  const api = { parsePostLink, normalizeAccount, originalUrl, validateRequest, imageKey, randomNumber, filename, extensionForMime, downloadSettings };
  root.XImageDownloader = api;
  if (typeof module !== 'undefined') module.exports = api;
})(globalThis);
