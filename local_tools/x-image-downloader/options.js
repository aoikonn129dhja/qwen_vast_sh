(() => {
  'use strict';
  const core = globalThis.XImageDownloader;
  const form = document.getElementById('settings-form');
  const fields = document.getElementById('settings-fields');
  const directory = document.getElementById('directory');
  const saveAs = document.getElementById('save-as');
  const status = document.getElementById('status');
  const preview = document.getElementById('preview');

  function settings() { return core.downloadSettings({ directory: directory.value, saveAs: saveAs.checked }); }
  function showStatus(text, error = false) {
    status.textContent = text;
    status.dataset.error = String(error);
  }
  function updatePreview() {
    try {
      const value = settings();
      preview.textContent = value.saveAs ? '保存時に場所を選択します。' :
        `保存先：Chromeのダウンロード先 / ${value.directory ? `${value.directory}/` : ''}投稿者ID＋乱数 (画像番号).jpg`;
    } catch (error) { preview.textContent = error.message; }
  }
  form.addEventListener('input', () => { showStatus(''); updatePreview(); });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (fields.disabled) return;
    try {
      const value = settings();
      fields.disabled = true;
      await chrome.storage.local.set({ downloadSettings: value });
      directory.value = value.directory;
      updatePreview();
      showStatus('保存しました。次のダウンロードから反映されます。');
    } catch (error) { showStatus(`保存できませんでした：${error.message}`, true); }
    finally { fields.disabled = false; }
  });
  (async () => {
    try {
      const stored = (await chrome.storage.local.get('downloadSettings')).downloadSettings;
      // Keep invalid legacy values editable instead of silently replacing them.
      directory.value = typeof stored?.directory === 'string' ? stored.directory : '';
      saveAs.checked = stored?.saveAs === true;
      updatePreview();
      fields.disabled = false;
    } catch (error) { showStatus(`設定を読み込めませんでした。画面を開き直してください：${error.message}`, true); }
  })();
})();
