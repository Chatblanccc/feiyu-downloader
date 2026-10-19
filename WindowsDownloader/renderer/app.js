'use strict';

const $ = (id) => document.getElementById(id);
const api = window.feather;
const DEFAULT_STYLE = Object.freeze({ fontScale: 1, colorHex: 'FFFFFF', position: 'bottom' });
const LANGUAGES = [
  ['en', '英语'], ['zh', '中文'], ['ja', '日语'], ['ko', '韩语'], ['fr', '法语'],
  ['de', '德语'], ['es', '西班牙语'], ['ru', '俄语'], ['pt', '葡萄牙语'],
  ['it', '意大利语'], ['ar', '阿拉伯语'], ['hi', '印地语'], ['th', '泰语'],
  ['vi', '越南语'], ['id', '印度尼西亚语'], ['nl', '荷兰语'], ['tr', '土耳其语'], ['uk', '乌克兰语']
];
const STATUS = {
  queued: '等待下载', pending: '等待处理', resolving: '正在获取信息', fetching: '正在获取信息',
  downloading: '正在下载', processing: '正在处理', merging: '正在合并', postprocessing: '正在整理文件',
  completed: '已完成', failed: '未完成', interrupted: '已中断', cancelled: '已取消', canceled: '已取消',
  cancelling: '正在取消', preparing: '正在准备', transcribing: '正在识别人声',
  translating: '正在翻译', burning: '正在添加字幕', exporting: '正在导出',
  recognizing: '正在识别人声', rendering: '正在添加字幕', muxing: '正在合成视频', running: '正在处理字幕',
  metadata: '正在检查视频', models: '正在检查语言资源', audio: '正在准备音频', speech: '正在识别人声', translate: '正在翻译', export: '正在导出'
};
const TERMINAL = new Set(['completed', 'failed', 'interrupted', 'cancelled', 'canceled']);
const ui = {
  view: 'all', state: { settings: {}, downloads: [], subtitles: [], models: {} },
  source: 'en', target: 'zh', textMode: 'bilingual', videoMode: 'burned', input: '',
  style: { ...DEFAULT_STYLE }, previewBusy: false, previewHidden: false, adding: false, preparing: false,
  starting: false, initialized: false, lastStyle: null, languageSignature: '',
  styleTimer: null, unsub: null, unsubUpdate: null, updateBusy: false, downloadRows: new Map(), subtitleRows: new Map(), lastNotice: null
};

function node(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined) el.textContent = String(text);
  return el;
}
function setText(id, text) { const el = $(id); if (el.textContent !== String(text ?? '')) el.textContent = String(text ?? ''); }
function basename(path) { return String(path || '').replace(/\\/g, '/').split('/').filter(Boolean).pop() || ''; }
function shortText(value, limit = 1200) { return String(value ?? '').slice(0, limit); }
function pathValue(value) {
  if (typeof value === 'string') return value;
  if (value && typeof value === 'object') return value.path || value.filePath || value.fileURL || value.input || '';
  return '';
}
function itemStatus(item) { return String(item?.state || item?.status || 'pending').toLowerCase(); }
function itemID(item) { return String(item?.id || item?.taskId || item?.url || ''); }
function completed(item) { return itemStatus(item) === 'completed'; }
function active(item) { return !TERMINAL.has(itemStatus(item)); }
function fraction(value) {
  if (value && typeof value === 'object') return fraction(value.fraction ?? value.percent ?? value.progress);
  const number = Number(value);
  if (value === null || value === undefined || value === '' || !Number.isFinite(number)) return null;
  return Math.max(0, Math.min(1, number > 1 ? number / 100 : number));
}
function progressOf(item) { return fraction(item?.fraction ?? item?.progress ?? item?.percent); }
function filePath(item) { return pathValue(item?.filePath || item?.fileURL || item?.output || item?.path || item?.result?.video || item?.result?.videoPath); }
function bytes(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n < 0) return '';
  if (n < 1024) return `${Math.round(n)} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}
function duration(seconds) {
  const n = Number(seconds);
  if (!Number.isFinite(n) || n <= 0) return '';
  const total = Math.round(n);
  return [total >= 3600 ? Math.floor(total / 3600) : null, Math.floor(total / 60) % 60, total % 60]
    .filter((v) => v !== null).map((v, i) => i ? String(v).padStart(2, '0') : String(v)).join(':');
}
function validStyle(value) {
  const style = value && typeof value === 'object' ? value : {};
  const scale = Number(style.fontScale);
  const hex = String(style.colorHex || '').replace(/^#/, '').toUpperCase();
  return {
    fontScale: Number.isFinite(scale) && scale >= .6 && scale <= 2 ? scale : 1,
    colorHex: /^[0-9A-F]{6}$/.test(hex) ? hex : 'FFFFFF',
    position: ['bottom', 'center', 'top'].includes(style.position) ? style.position : 'bottom'
  };
}
function notice(message, error = false) {
  const box = $('notice');
  setText('notice-text', shortText(message, 1600));
  box.classList.toggle('warning', error);
  box.hidden = !message;
}
function errorMessage(error) { return shortText(error?.message || error || '暂时未能完成，请稍后重试。'); }
function itemDetail(item, fallback = '') { return item?.error ? errorMessage(item.error) : shortText(item?.detail || item?.message || fallback); }
async function call(method, ...args) {
  if (!api || typeof api[method] !== 'function') throw new Error('应用连接尚未准备好，请关闭并重新打开飞羽下载。');
  return api[method](...args);
}
async function action(method, ...args) {
  try { return await call(method, ...args); }
  catch (error) { notice(errorMessage(error), true); return undefined; }
}
function actionButton(label, callback, className = '') {
  const button = node('button', `plain ${className}`.trim(), label);
  button.type = 'button';
  button.addEventListener('click', callback);
  return button;
}
function progressElement(value, label) {
  const progress = node('progress');
  progress.max = 1;
  if (value !== null) progress.value = value;
  progress.setAttribute('aria-label', label);
  return progress;
}
function subtitleBusy() {
  if (ui.starting) return true;
  const progress = ui.state.subtitleProgress;
  if (progress && !TERMINAL.has(itemStatus(progress))) return true;
  return (ui.state.subtitles || []).some(active);
}
function modelsBusy() {
  const status = String(ui.state.models?.status || '').toLowerCase();
  return ui.preparing || ['preparing', 'downloading', 'loading', 'verifying', 'extracting'].includes(status);
}
function toolsReady() { return ui.state.toolsReady !== false; }
function requestOptions() {
  return {
    text: $('share-text').value.trim(), quality: $('quality-select').value,
    browser: $('browser-select').value, cookiesFile: ui.state.settings?.cookiesFile || ''
  };
}
function applySettings(settings) {
  if (!ui.initialized || settings.quality !== undefined) $('quality-select').value = settings.quality || 'best';
  if (!ui.initialized || settings.browser !== undefined) $('browser-select').value = settings.browser || 'none';
  const remoteStyle = JSON.stringify(validStyle(settings.style));
  const editingStyle = ['font-scale', 'custom-color'].includes(document.activeElement?.id);
  if (!ui.initialized || (remoteStyle !== ui.lastStyle && !ui.styleTimer && !editingStyle)) {
    ui.style = validStyle(settings.style);
    renderStyle();
  }
  ui.lastStyle = remoteStyle;
  const destination = settings.destination || '本机下载文件夹';
  setText('settings-destination', destination);
  setText('footer-destination', `保存到  ${destination}`);
  $('footer-folder').title = destination;
  $('settings-destination').title = destination;
  ['footer-folder', 'open-downloads', 'queue-folder'].forEach((id) => {
    $(id).setAttribute('aria-label', `打开下载文件夹：${destination}`);
  });
  $('change-directory').setAttribute('aria-label', `更改视频保存位置，当前：${destination}`);
  renderLogin();
}
function renderLogin() {
  const browser = $('browser-select').value;
  $('choose-cookies').hidden = browser !== 'file';
  $('open-website').hidden = browser !== 'session';
  $('cookies-path').hidden = browser !== 'file' || !ui.state.settings?.cookiesFile;
  setText('cookies-path', ui.state.settings?.cookiesFile || '');
  setText('login-explanation', browser === 'none'
    ? '直接粘贴链接即可下载，公开抖音视频会自动解析，无须切换登录状态。仅在网站要求登录或验证时，再选择登录方式。'
    : browser === 'session' ? '粘贴链接后点击「打开视频网站」。在新窗口中完成网站验证或登录，确认视频可播放后关闭窗口，再返回解析或下载。会话仅保存在本机。'
      : browser === 'file' ? '请选用你自行导出的 Cookie 文件，登录信息仅用于本机对应网站的请求。'
        : `仅在你添加或重试任务时，读取所选 ${browser === 'chrome' ? 'Chrome' : browser === 'edge' ? 'Edge' : 'Firefox'} 的登录状态。Chrome/Edge 在 Windows 上可能无法解密，可改用「应用内网站会话」。`);
}
function renderView() {
  const subtitles = ui.view === 'subtitles';
  $('download-workspace').hidden = subtitles;
  $('subtitle-workspace').hidden = !subtitles;
  const titles = { all: ['全部任务', '把喜欢的视频，留在身边。'], active: ['下载中', '正在下载的视频，一目了然。'], completed: ['已完成', '已经保存好的视频，随时打开。'], subtitles: ['翻译与字幕', '选好语言，让视频更容易看懂。'] };
  setText('page-title', titles[ui.view][0]);
  setText('page-subtitle', titles[ui.view][1]);
  document.querySelectorAll('[data-view]').forEach((button) => {
    const selected = button.dataset.view === ui.view;
    button.classList.toggle('selected', selected);
    if (selected) button.setAttribute('aria-current', 'page'); else button.removeAttribute('aria-current');
  });
  renderDownloads();
}
function syncRows(container, map, items, builder) {
  const ids = new Set();
  items.forEach((item, index) => {
    const id = itemID(item) || `index-${index}`;
    ids.add(id);
    const signature = builder === buildDownloadRow ? JSON.stringify([
      id, itemStatus(item), item.title, item.url, item.platform, item.extractor, filePath(item), item.error
    ]) : JSON.stringify(item);
    let entry = map.get(id);
    if (!entry || entry.signature !== signature) {
      const row = builder(item);
      if (entry) entry.row.replaceWith(row);
      entry = { row, signature };
      map.set(id, entry);
    }
    if (typeof entry.row.update === 'function') entry.row.update(item);
    const atIndex = container.children[index];
    if (atIndex !== entry.row) container.insertBefore(entry.row, atIndex || null);
  });
  for (const [id, entry] of map) {
    if (!ids.has(id)) { entry.row.remove(); map.delete(id); }
  }
}
function platformLabel(item) {
  const platform = String(item.platform || item.extractor || item.metadata?.extractor || '').replace(/[^\w\u4e00-\u9fa5 .-]/g, '').slice(0, 12);
  if (/bili/i.test(platform)) return 'B站';
  if (/douyin/i.test(platform)) return '抖音';
  if (/youtube/i.test(platform)) return 'YT';
  if (/twitter|^x$/i.test(platform)) return 'X';
  if (/tiktok/i.test(platform)) return 'TikTok';
  return platform || '视频';
}
function renderDownloads() {
  const all = Array.isArray(ui.state.downloads) ? ui.state.downloads : [];
  setText('all-count', all.length);
  setText('active-count', all.filter(active).length || '');
  setText('completed-count', all.filter(completed).length || '');
  const visible = all.filter((item) => ui.view === 'active' ? active(item) : ui.view === 'completed' ? completed(item) : true);
  setText('task-list-title', ui.view === 'active' ? '正在下载' : ui.view === 'completed' ? '已保存的视频' : '下载任务');
  setText('task-summary', visible.length ? `${visible.length} 个任务` : '');
  syncRows($('download-list'), ui.downloadRows, visible, buildDownloadRow);
  $('download-empty').hidden = visible.length !== 0;
  const emptyTitle = $('download-empty').querySelector('h3');
  const emptyCopy = $('download-empty').querySelector('p');
  emptyTitle.textContent = ui.view === 'active' ? '当前没有正在下载的任务' : ui.view === 'completed' ? '下载好的视频会出现在这里' : '从一条链接开始';
  emptyCopy.textContent = ui.view === 'active' ? '添加新的视频后，可以在这里查看下载进度。' : '粘贴分享链接，添加后可在这里查看下载进度。';
  const videos = all.filter((item) => completed(item) && filePath(item) && /\.(mp4|mkv|webm|mov|m4v|avi)$/i.test(filePath(item))).slice(0, 100);
  const signature = videos.map((item) => `${itemID(item)}:${filePath(item)}`).join('|');
  if ($('downloaded-videos').dataset.signature !== signature) {
    const select = $('downloaded-videos');
    select.replaceChildren(node('option', '', '已下载的视频'));
    select.firstChild.value = '';
    for (const item of videos) { const option = node('option', '', shortText(item.title || basename(filePath(item)), 80)); option.value = filePath(item); select.append(option); }
    select.dataset.signature = signature;
  }
  $('downloaded-videos').disabled = !videos.length || subtitleBusy();
  renderPreview();
}
function buildDownloadRow(item) {
  const status = itemStatus(item), id = itemID(item), done = completed(item), running = active(item);
  const row = node('article', 'task-card');
  row.dataset.taskId = id;
  row.append(node('div', 'task-icon', platformLabel(item)));
  const copy = node('div', 'task-copy');
  const top = node('div', 'task-top');
  const title = node('h3', 'task-title', shortText(item.title || item.url || '正在获取视频信息…', 300));
  title.title = shortText(item.title || item.url || '', 600);
  top.append(title, node('span', `task-status ${done ? 'complete' : status === 'failed' ? 'error' : ''}`, STATUS[status] || shortText(item.statusLabel || status, 40)));
  copy.append(top);
  const detailElement = node('p', `task-detail ${item.error ? 'error' : ''}`);
  const metadata = node('div', 'task-metadata');
  copy.append(detailElement, metadata);
  let progressBar, percent;
  if (running) {
    const progress = progressOf(item), line = node('div', 'task-progress-line');
    progressBar = progressElement(progress, '视频下载进度');
    percent = node('span', 'task-percent');
    line.append(progressBar, percent);
    copy.append(line);
  }
  const actions = node('div', 'task-actions');
  if (done && filePath(item)) {
    const video = /\.(mp4|mkv|webm|mov|m4v|avi|wmv|flv)$/i.test(filePath(item));
    actions.append(actionButton(video ? '打开视频' : '打开文件', () => action('openFile', filePath(item))), actionButton('在文件夹中显示', () => action('revealFile', filePath(item))));
    if (video) actions.append(actionButton('翻译与字幕', () => { selectVideo(filePath(item)); ui.view = 'subtitles'; renderView(); $('content-scroll').scrollTop = 0; }));
  } else if (running) {
    const cancel = actionButton(status === 'cancelling' ? '正在取消…' : '取消下载', () => action('cancelDownload', id));
    cancel.disabled = status === 'cancelling'; actions.append(cancel);
  } else actions.append(actionButton('重新下载', () => action('retryDownload', id)));
  if (!running) actions.append(actionButton('移除记录', () => action('removeDownload', id), 'danger'));
  if (actions.children.length) copy.append(actions);
  row.append(copy);
  row.update = (value) => {
    const detail = itemDetail(value, done ? basename(filePath(value)) : '');
    if (detailElement.textContent !== detail) detailElement.textContent = detail;
    detailElement.hidden = !detail;
    const live = value.progress && typeof value.progress === 'object' ? value.progress : {};
    const total = bytes(value.totalBytes || live.totalBytes || value.filesize || value.fileSize || value.bytes);
    const downloaded = running ? bytes(value.downloadedBytes ?? live.downloadedBytes) : '';
    const speed = value.speedBytesPerSecond ?? live.speedBytesPerSecond ?? value.speed;
    const eta = value.etaSeconds ?? live.etaSeconds ?? value.eta;
    const info = [duration(value.duration || value.metadata?.duration), downloaded && total ? `${downloaded} / ${total}` : total || downloaded, speed ? `${typeof speed === 'number' ? bytes(speed) : speed}/s` : '', eta ? `剩余 ${typeof eta === 'number' ? duration(eta) : eta}` : ''].filter(Boolean).join('  ·  ');
    if (metadata.textContent !== info) metadata.textContent = info;
    metadata.hidden = !info;
    if (progressBar) {
      const progress = progressOf(value);
      if (progress === null) progressBar.removeAttribute('value'); else progressBar.value = progress;
      const label = progress === null ? '' : `${Math.floor(progress * 100)}%`;
      if (percent.textContent !== label) percent.textContent = label;
    }
  };
  return row;
}
function renderPreview() {
  const region = $('preview-region');
  const preview = ui.state.preview;
  region.hidden = ui.previewHidden || (!preview && !ui.previewBusy);
  if (region.hidden) { region.replaceChildren(); return; }
  const signature = JSON.stringify([preview, ui.previewBusy]);
  if (region.dataset.signature === signature) return;
  region.dataset.signature = signature;
  const items = Array.isArray(preview) ? preview : preview?.items || (preview ? [preview] : []);
  const card = node('div', 'card preview-card');
  card.append(node('span', 'preview-badge', ui.previewBusy ? '查询中' : '视频信息'));
  const copy = node('div', 'task-copy');
  if (ui.previewBusy) { copy.append(node('h3', '', '正在获取视频信息…'), node('p', '', '部分网站需要更长时间，请稍候。')); }
  else if (preview?.error) copy.append(node('p', 'error-text', errorMessage(preview.error)));
  else {
    for (const item of items.slice(0, 5)) {
      copy.append(node('h3', '', shortText(item.title || item.url || '已获取视频信息', 300)));
      const details = [item.uploader || item.author, duration(item.duration), item.platform || item.extractor, item.resolution].filter(Boolean);
      if (details.length) copy.append(node('p', '', details.join('  ·  ')));
    }
    if (items.length > 5) copy.append(node('p', '', `另外还有 ${items.length - 5} 条视频信息。`));
  }
  card.append(copy, actionButton('收起', () => { ui.previewHidden = true; ui.state.preview = null; renderPreview(); }));
  region.replaceChildren(card);
}
function languageEntries() {
  const values = ui.state.models?.languages || ui.state.languages;
  if (!Array.isArray(values) || !values.length) return LANGUAGES;
  return values.map((value) => typeof value === 'string' ? [value, LANGUAGES.find(([code]) => code === value)?.[1] || value] : [value.id || value.code, value.name || value.title || value.id || value.code]).filter(([code]) => typeof code === 'string' && code);
}
function renderLanguages() {
  const languages = languageEntries();
  const signature = JSON.stringify(languages);
  if (signature === ui.languageSignature) return;
  ui.languageSignature = signature;
  for (const [id, key] of [['source-language', 'source'], ['target-language', 'target']]) {
    const select = $(id);
    select.replaceChildren();
    for (const [value, label] of languages) { const option = node('option', '', label); option.value = value; select.append(option); }
    if (!languages.some(([code]) => code === ui[key])) ui[key] = key === 'source' ? languages[0][0] : languages.find(([code]) => code !== ui.source)?.[0] || languages[0][0];
    select.value = ui[key];
  }
}
function selectVideo(path) {
  if (!path || subtitleBusy()) return;
  ui.input = path;
  setText('selected-video-title', basename(path));
  setText('selected-video-path', path);
  $('selected-video-title').title = path;
  $('downloaded-videos').value = '';
  renderSubtitleControls();
}
function setSegment(groupID, value) {
  $(groupID).querySelectorAll('button').forEach((button) => {
    const selected = button.dataset.value === value;
    button.classList.toggle('selected', selected);
    button.setAttribute('aria-pressed', String(selected));
  });
}
function renderStyle() {
  ui.style = validStyle(ui.style);
  const percent = Math.round(ui.style.fontScale * 100);
  $('font-scale').value = String(percent);
  setText('font-scale-label', `${percent}%`);
  $('font-scale').setAttribute('aria-valuetext', `${percent}%`);
  $('custom-color').value = `#${ui.style.colorHex}`;
  setText('color-value', `#${ui.style.colorHex}`);
  $('color-presets').querySelectorAll('button').forEach((button) => {
    const selected = button.dataset.color === ui.style.colorHex;
    button.classList.toggle('selected', selected); button.setAttribute('aria-pressed', String(selected));
  });
  setSegment('position-modes', ui.style.position);
  const caption = $('preview-caption');
  caption.textContent = ui.textMode === 'original' ? 'Every story deserves to be understood.' : ui.textMode === 'translated' ? '让每一段故事都听得懂。' : 'Every story deserves to be understood.\n让每一段故事都听得懂。';
  caption.style.color = `#${ui.style.colorHex}`;
  caption.style.fontSize = `${11 * ui.style.fontScale}px`;
  $('style-preview').style.alignItems = ui.style.position === 'top' ? 'flex-start' : ui.style.position === 'center' ? 'center' : 'flex-end';
  $('style-preview').setAttribute('aria-label', `字幕预览，${({ bottom: '底部', center: '居中', top: '顶部' })[ui.style.position]}，字号 ${percent}%`);
  fitPreviewCaption();
}
function fitPreviewCaption() {
  const preview = $('style-preview'), caption = $('preview-caption');
  if (!preview.clientWidth) return;
  // The small sample frame fits long bilingual text just as a video subtitle wraps.
  // Keep the requested setting intact; only this demonstration adapts to its frame.
  let size = 11 * ui.style.fontScale;
  caption.style.fontSize = `${size}px`;
  const maximum = preview.clientHeight - 18;
  for (let pass = 0; pass < 32 && caption.getBoundingClientRect().height > maximum && size > 6; pass++) {
    size -= .5;
    caption.style.fontSize = `${size}px`;
  }
}
function saveStyle() {
  renderStyle();
  clearTimeout(ui.styleTimer);
  ui.styleTimer = setTimeout(async () => {
    ui.styleTimer = null;
    await action('saveSettings', { style: { ...ui.style } });
  }, 180);
}
function renderSubtitleControls() {
  const busy = subtitleBusy(), preparing = modelsBusy(), burned = ui.videoMode === 'burned';
  $('choose-video').disabled = busy;
  $('source-language').disabled = busy || preparing;
  $('target-language').disabled = busy || preparing || ui.textMode === 'original';
  $('video-mode').disabled = busy;
  $('text-modes').querySelectorAll('button').forEach((el) => { el.disabled = busy; });
  $('style-editor').classList.toggle('inactive', !burned || busy);
  $('style-editor').querySelectorAll('button,input').forEach((el) => { el.disabled = !burned || busy; });
  $('start-subtitle').disabled = !ui.input || busy || preparing || !toolsReady();
  setText('start-subtitle', busy ? '正在处理…' : '开始生成字幕');
  $('cancel-subtitle').hidden = !busy;
  const current = ui.state.subtitleProgress || (ui.state.subtitles || []).find(active);
  $('cancel-subtitle').disabled = itemStatus(current) === 'cancelling';
  setText('cancel-subtitle', itemStatus(current) === 'cancelling' ? '正在取消…' : '取消处理');
  setText('output-explanation', ({
    burned: '导出 SRT 和字幕直接显示在画面中的视频，方便直接观看和分享。画面会重新编码，原视频和原声保留。',
    soft: '导出 SRT 和带可开关字幕的视频。若没有显示字幕，请在播放器中打开字幕轨道。',
    none: '导出 SRT 字幕文件，可导入播放器或剪辑软件。'
  })[ui.videoMode]);
  setText('style-explanation', burned ? '样式将直接绘制到视频画面中；预览用于观察字号、颜色和位置。' : 'SRT 和可开关字幕的显示样式由播放器控制；这里的样式仅用于字幕直接显示在画面中的视频。');
  renderModels();
}
function renderModels() {
  const model = ui.state.models || {}, preparing = modelsBusy();
  const ready = model.ready === true || String(model.status).toLowerCase() === 'ready';
  setText('model-title', preparing ? '正在准备语言资源' : ready ? '语言资源已准备好' : '准备语言资源');
  const modelProgress = model.progress && typeof model.progress === 'object' ? model.progress : {};
  const byteSummary = preparing && modelProgress.totalBytes ? ` · ${bytes(modelProgress.bytes || 0)} / ${bytes(modelProgress.totalBytes)}` : !ready && model.bytesTotal ? `（约 ${bytes(model.bytesTotal)}）` : '';
  setText('model-detail', shortText((model.detail || model.message || modelProgress.message || (preparing ? '请等待下载和校验完成，完成后才能开始生成字幕。' : ready ? '所需资源已保存到本机，可以开始处理视频。' : '语言资源下载到本机后，即可离线识别和翻译。')) + byteSummary));
  $('model-progress').hidden = !preparing;
  const value = fraction(model.progress ?? model.fraction);
  if (value === null) $('model-progress').removeAttribute('value'); else $('model-progress').value = value;
  $('model-error').hidden = !model.error;
  setText('model-error', model.error ? errorMessage(model.error) : '');
  $('prepare-models').hidden = preparing;
  $('prepare-models').disabled = subtitleBusy();
  setText('prepare-models', ready ? '检查语言资源' : '准备语言资源');
  $('cancel-models').hidden = !preparing;
  $('cancel-models').disabled = String(model.status).toLowerCase() === 'cancelling';
}
function subtitleResult(item) {
  const result = item.result || {};
  const files = Array.isArray(result.files) ? result.files.filter((p) => typeof p === 'string') : [];
  return {
    video: pathValue(result.video || result.videoPath || item.videoPath || item.outputVideo || files.find((p) => /\.(mp4|mkv|webm|mov|m4v)$/i.test(p))),
    subtitles: pathValue(result.subtitles || result.subtitlePath || result.srt || item.subtitlePath || item.outputSrt || files.find((p) => /\.srt$/i.test(p))),
    folder: pathValue(result.directory || result.destination || item.outputDirectory)
  };
}
function addResultActions(actions, item) {
  const result = subtitleResult(item), show = result.video || result.subtitles || result.folder;
  if (show) actions.append(actionButton('在文件夹中显示', () => action('revealFile', show)));
  if (result.subtitles) actions.append(actionButton('打开字幕', () => action('openFile', result.subtitles)));
  if (result.video) actions.append(actionButton('播放视频', () => action('openFile', result.video)));
}
function renderSubtitles() {
  const items = Array.isArray(ui.state.subtitles) ? ui.state.subtitles : [];
  const current = ui.state.subtitleProgress || items.find(active);
  $('subtitle-current').hidden = !current;
  if (current) {
    const card = node('div', 'subtitle-current-card'), status = itemStatus(current), amount = progressOf(current);
    const stage = current.stage || current.progress?.stage;
    card.append(node('h3', '', `${STATUS[stage] || STATUS[status] || '正在处理字幕'}${amount !== null ? ` · ${Math.floor(amount * 100)}%` : ''}`));
    if (!TERMINAL.has(status)) card.append(progressElement(amount, '字幕处理进度'));
    card.append(node('p', current.error ? 'error-text' : '', itemDetail(current)));
    if (completed(current)) { const actions = node('div', 'task-actions'); addResultActions(actions, current); card.append(actions); }
    $('subtitle-current').replaceChildren(card);
  }
  const history = items.filter((item) => !active(item)).slice(0, 30);
  $('subtitle-history-heading').hidden = !history.length;
  syncRows($('subtitle-list'), ui.subtitleRows, history, buildSubtitleRow);
  renderSubtitleControls();
}
function buildSubtitleRow(item) {
  const request = item.request || item, status = itemStatus(item), row = node('article', 'task-card');
  row.append(node('div', 'task-icon', '字幕'));
  const copy = node('div', 'task-copy'), top = node('div', 'task-top');
  top.append(node('h3', 'task-title', basename(pathValue(request.input || item.input)) || item.title || '字幕任务'), node('span', `task-status ${completed(item) ? 'complete' : status === 'failed' ? 'error' : ''}`, STATUS[status] || status));
  copy.append(top);
  const source = LANGUAGES.find(([id]) => id === request.source)?.[1] || request.source;
  const target = LANGUAGES.find(([id]) => id === request.target)?.[1] || request.target;
  const textMode = ({ original: '仅原文', translated: '仅译文', bilingual: '原文 + 译文' })[request.textMode];
  const details = [request.textMode === 'original' ? source : source && target ? `${source} → ${target}` : '', textMode].filter(Boolean);
  if (details.length) copy.append(node('div', 'task-metadata', details.join('  ·  ')));
  if (item.error || item.detail) copy.append(node('p', `task-detail ${item.error ? 'error' : ''}`, itemDetail(item)));
  const actions = node('div', 'task-actions');
  const retry = actionButton('再次处理', async () => {
    if (subtitleBusy()) return;
    await action('retrySubtitle', itemID(item));
  });
  retry.disabled = subtitleBusy(); actions.append(retry);
  row.update = () => { retry.disabled = subtitleBusy(); };
  if (completed(item)) addResultActions(actions, item);
  copy.append(actions); row.append(copy); return row;
}
function renderUpdate(update = ui.state.update || {}) {
  ui.state.update = update;
  const status = update.status || 'idle';
  const titles = { idle: '软件更新', unavailable: '软件更新', checking: '正在检查更新…', 'up-to-date': '已是最新版本', available: `发现新版本 ${update.version || ''}`, downloading: '正在下载更新…', cancelling: '正在取消下载…', cancelled: '已取消下载', downloaded: '更新已下载', installing: '正在保存并安装更新…', error: '更新暂未完成' };
  setText('update-title', titles[status] || '软件更新');
  let detail = '点击检查 GitHub 上的新版本。';
  if (status === 'unavailable') detail = '检查更新仅适用于安装后的 Windows 版本。';
  else if (status === 'checking') detail = '正在连接 GitHub，请稍候。';
  else if (status === 'up-to-date') detail = `当前版本 ${update.currentVersion || ''} 已是最新版本。`;
  else if (status === 'available') detail = `新版本 ${update.version} · ${bytes(update.size)}。下载完成后由你确认重启更新。`;
  else if (status === 'downloading') detail = `${bytes(update.progress?.transferred)} / ${bytes(update.progress?.total || update.size)}${update.progress?.bytesPerSecond ? ` · ${bytes(update.progress.bytesPerSecond)}/s` : ''}`;
  else if (status === 'cancelling') detail = '正在停止下载，请稍候。';
  else if (status === 'cancelled') detail = '可以重新检查更新后再次下载。';
  else if (status === 'downloaded') detail = update.installBlocked ? update.busyMessage : `新版本 ${update.version} 已完成校验，点击「重启并更新」即可安装。`;
  else if (status === 'installing') detail = '正在保存设置和历史记录，随后将重新打开飞羽下载。';
  else if (status === 'error') detail = '请根据下方提示重试。';
  setText('update-detail', detail);
  setText('update-notes', shortText(update.notes, 16000));
  $('update-notes').hidden = !update.notes;
  $('update-progress').hidden = !['downloading', 'cancelling'].includes(status);
  $('update-progress').value = Number(update.progress?.percent) || 0;
  setText('update-error', update.error || ''); $('update-error').hidden = !update.error;
  const working = ui.updateBusy || ['checking', 'downloading', 'cancelling', 'installing'].includes(status);
  $('update-check').disabled = working || ['unavailable', 'downloaded'].includes(status);
  $('check-for-updates').disabled = working;
  $('update-download').hidden = status !== 'available'; $('update-download').disabled = ui.updateBusy;
  $('update-cancel').hidden = !['downloading', 'cancelling'].includes(status); $('update-cancel').disabled = status === 'cancelling';
  $('update-install').hidden = status !== 'downloaded'; $('update-install').disabled = ui.updateBusy || !!update.installBlocked;
}
async function updateAction(method) {
  if (ui.updateBusy) return;
  ui.updateBusy = true; renderUpdate();
  try { renderUpdate(await call(method)); }
  catch (error) { renderUpdate({ ...ui.state.update, error: errorMessage(error) }); }
  finally { ui.updateBusy = false; renderUpdate(); }
}

function renderState(state) {
  if (!state || typeof state !== 'object') return;
  ui.state = { ...ui.state, ...state, settings: { ...ui.state.settings, ...state.settings }, models: { ...ui.state.models, ...state.models } };
  if (!Array.isArray(ui.state.downloads)) ui.state.downloads = [];
  if (!Array.isArray(ui.state.subtitles)) ui.state.subtitles = [];
  applySettings(ui.state.settings);
  renderLanguages();
  renderDownloads();
  renderSubtitles();
  if (ui.state.notice && ui.state.notice !== ui.lastNotice) { ui.lastNotice = ui.state.notice; notice(ui.state.notice, true); }
  $('tools-notice').hidden = toolsReady();
  const version = typeof ui.state.version === 'object' ? ui.state.version.version : ui.state.version;
  setText('sidebar-version', version || 'Windows');
  setText('footer-version', `飞羽下载 ${version || 'Windows 版'}`);
  setText('about-version', `Windows 版${version ? ` · ${version}` : ''}`);
  renderUpdate();
  const disabled = ui.adding || !toolsReady() || !$('share-text').value.trim();
  $('download-button').disabled = disabled;
  $('preview-button').disabled = ui.previewBusy || !toolsReady() || !$('share-text').value.trim();
  ui.initialized = true;
}

document.querySelectorAll('[data-view]').forEach((button) => button.addEventListener('click', () => {
  ui.view = button.dataset.view; renderView(); $('content-scroll').scrollTop = 0;
}));
$('dismiss-notice').addEventListener('click', () => notice(''));
$('share-text').addEventListener('input', () => {
  $('download-button').disabled = ui.adding || !toolsReady() || !$('share-text').value.trim();
  $('preview-button').disabled = ui.previewBusy || !toolsReady() || !$('share-text').value.trim();
});
$('share-text').addEventListener('keydown', (event) => { if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') { event.preventDefault(); if (!$('download-button').disabled) $('download-button').click(); } });
$('quality-select').addEventListener('change', () => action('saveSettings', { quality: $('quality-select').value }));
$('browser-select').addEventListener('change', () => { renderLogin(); action('saveSettings', { browser: $('browser-select').value }); });
$('open-website').addEventListener('click', async () => {
  const text = $('share-text').value.trim();
  if (!text) { notice('请先粘贴需要下载的视频链接。', true); return; }
  $('open-website').disabled = true;
  try { await call('saveSettings', { browser: 'session' }); await call('openWebsite', text); }
  catch (error) { notice(errorMessage(error), true); }
  finally { $('open-website').disabled = false; }
});
$('choose-cookies').addEventListener('click', async () => {
  const result = await action('chooseCookiesFile'), path = pathValue(result);
  if (path) { ui.state.settings.cookiesFile = path; await action('saveSettings', { cookiesFile: path, browser: 'file' }); renderLogin(); }
});
$('preview-button').addEventListener('click', async () => {
  const options = requestOptions(); if (!options.text || ui.previewBusy) return;
  ui.previewHidden = false; ui.previewBusy = true; $('preview-button').disabled = true; renderPreview();
  try {
    const result = await call('preview', options);
    if (result && typeof result === 'object') ui.state.preview = result.preview ?? result;
  } catch (error) { ui.state.preview = { error: errorMessage(error) }; }
  finally { ui.previewBusy = false; renderPreview(); $('preview-button').disabled = !$('share-text').value.trim() || !toolsReady(); }
});
$('download-button').addEventListener('click', async () => {
  const options = requestOptions(); if (!options.text || ui.adding) return;
  ui.previewHidden = true; renderPreview();
  ui.adding = true; $('download-button').disabled = true; setText('download-button', '正在添加…');
  try {
    await call('addDownloads', options);
    $('share-text').value = ''; ui.state.preview = null; renderPreview();
    ui.view = 'all'; renderView();
  } catch (error) { notice(errorMessage(error), true); }
  finally { ui.adding = false; setText('download-button', '添加下载'); $('download-button').disabled = !$('share-text').value.trim() || !toolsReady(); }
});
const openDownloads = () => {
  if (api && typeof api.openDownloadDirectory === 'function') { action('openDownloadDirectory'); return; }
  const path = ui.state.settings?.destination;
  if (path) action('openFile', path); else notice('下载文件夹尚未准备好，请在设置中选择保存位置。');
};
['open-downloads', 'queue-folder', 'footer-folder'].forEach((id) => $(id).addEventListener('click', openDownloads));
$('settings-button').addEventListener('click', () => $('settings-dialog').showModal());
$('about-button').addEventListener('click', () => $('about-dialog').showModal());
$('check-for-updates').addEventListener('click', () => { $('about-dialog').showModal(); void updateAction('checkUpdate'); });
$('update-check').addEventListener('click', () => updateAction('checkUpdate'));
$('update-download').addEventListener('click', () => updateAction('downloadUpdate'));
$('update-cancel').addEventListener('click', async () => { try { renderUpdate(await call('cancelUpdate')); } catch (error) { notice(errorMessage(error), true); } });
$('update-install').addEventListener('click', () => updateAction('installUpdate'));
$('change-directory').addEventListener('click', async () => {
  const result = await action('chooseDownloadDirectory'), path = pathValue(result);
  if (path) { ui.state.settings.destination = path; await action('saveSettings', { destination: path }); applySettings(ui.state.settings); }
});
$('choose-video').addEventListener('click', async () => { const result = await action('chooseVideo'); selectVideo(pathValue(result)); });
$('downloaded-videos').addEventListener('change', (event) => selectVideo(event.target.value));
$('source-language').addEventListener('change', (event) => { ui.source = event.target.value; renderSubtitleControls(); });
$('target-language').addEventListener('change', (event) => { ui.target = event.target.value; renderSubtitleControls(); });
$('text-modes').querySelectorAll('button').forEach((button) => button.addEventListener('click', () => { ui.textMode = button.dataset.value; setSegment('text-modes', ui.textMode); renderStyle(); renderSubtitleControls(); }));
$('video-mode').addEventListener('change', (event) => { ui.videoMode = event.target.value; renderSubtitleControls(); });
$('font-scale').addEventListener('input', (event) => { ui.style.fontScale = Number(event.target.value) / 100; saveStyle(); });
$('custom-color').addEventListener('input', (event) => { ui.style.colorHex = event.target.value.replace('#', '').toUpperCase(); saveStyle(); });
$('color-presets').querySelectorAll('button').forEach((button) => button.addEventListener('click', () => { ui.style.colorHex = button.dataset.color; saveStyle(); }));
$('position-modes').querySelectorAll('button').forEach((button) => button.addEventListener('click', () => { ui.style.position = button.dataset.value; saveStyle(); }));
$('reset-style').addEventListener('click', () => { ui.style = { ...DEFAULT_STYLE }; saveStyle(); });
$('prepare-models').addEventListener('click', async () => {
  if (modelsBusy() || subtitleBusy()) return;
  ui.preparing = true; renderSubtitleControls();
  try { await call('prepareModels', { source: ui.source, target: ui.textMode === 'original' ? ui.source : ui.target }); }
  catch (error) { notice(errorMessage(error), true); }
  finally { ui.preparing = false; renderSubtitleControls(); }
});
$('cancel-models').addEventListener('click', () => action('cancelModelPreparation'));
$('start-subtitle').addEventListener('click', async () => {
  if (!ui.input || subtitleBusy() || modelsBusy()) return;
  ui.starting = true; renderSubtitleControls();
  try {
    await call('startSubtitle', { input: ui.input, source: ui.source, target: ui.target, textMode: ui.textMode, videoMode: ui.videoMode, style: { ...ui.style } });
  } catch (error) { notice(errorMessage(error), true); }
  finally { ui.starting = false; renderSubtitleControls(); }
});
$('cancel-subtitle').addEventListener('click', () => action('cancelSubtitle'));
window.addEventListener('beforeunload', () => { clearTimeout(ui.styleTimer); if (typeof ui.unsub === 'function') ui.unsub(); if (typeof ui.unsubUpdate === 'function') ui.unsubUpdate(); });
new ResizeObserver(fitPreviewCaption).observe($('style-preview'));

renderStyle();
renderLanguages();
renderSubtitleControls();
$('download-button').disabled = true;
$('preview-button').disabled = true;
if (!api) {
  notice('应用连接尚未准备好，请关闭并重新打开飞羽下载。', true);
  $('start-subtitle').disabled = true;
} else {
  if (typeof api.onUpdate === 'function') ui.unsubUpdate = api.onUpdate(renderUpdate);
  try { ui.unsub = api.onState((state) => renderState(state)); }
  catch (error) { notice(errorMessage(error), true); }
  call('getState').then(renderState).catch((error) => notice(errorMessage(error), true));
}
