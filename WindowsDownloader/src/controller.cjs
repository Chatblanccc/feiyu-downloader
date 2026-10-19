'use strict';
const { EventEmitter } = require('node:events');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const crypto = require('node:crypto');
const { isDeepStrictEqual } = require('node:util');
const { DownloadManager, parseShareLinks, atomicJSON } = require('./core');
const ACTIVE = new Set(['preparing', 'running']);
const DEFAULT_STYLE = { fontScale: 1, colorHex: 'FFFFFF', position: 'bottom' };
const copy = x => JSON.parse(JSON.stringify(x));
function message(error) {
  if (error?.name === 'AbortError' || error?.code === 'cancelled') return '已取消。';
  return String((typeof error === 'string' ? error : error?.message) || '处理失败，请稍后重试。').replace(/https?:\/\/\S+/g, '[链接]').slice(0, 1000);
}
async function readJSON(file, fallback, max = 4 * 1024 * 1024) {
  try { const s = await fs.stat(file); if (s.size > max) throw new Error('记录过大'); return JSON.parse(await fs.readFile(file, 'utf8')); }
  catch (e) { if (e.code === 'ENOENT') return fallback; throw new Error('本机记录无法读取，原文件已保留，请检查应用数据目录。'); }
}
function style(value = DEFAULT_STYLE) {
  if (!value || !Number.isFinite(value.fontScale) || value.fontScale < .6 || value.fontScale > 2 || !/^[0-9A-Fa-f]{6}$/.test(value.colorHex) || !['top', 'center', 'bottom'].includes(value.position)) throw new Error('字幕样式无效，请调整字号、颜色或位置后重试。');
  return { fontScale: value.fontScale, colorHex: value.colorHex.toUpperCase(), position: value.position };
}
class FeatherController extends EventEmitter {
  constructor({ dataDirectory, downloadDirectory, tools, version = '0.3.2', engine, environment, sessionAuthentication, sessionMetadata, anonymousMetadata } = {}) {
    super(); Object.assign(this, { dataDirectory, tools, version, environment });
    this.settingsFile = path.join(dataDirectory, 'settings.json'); this.subtitlesFile = path.join(dataDirectory, 'subtitle-history.json');
    this.settings = { destination: downloadDirectory, quality: 'best', browser: 'none', cookiesFile: '', style: { ...DEFAULT_STYLE } };
    this.downloads = new DownloadManager({ tools, dataDirectory, downloadDirectory, environment, sessionAuthentication, sessionMetadata, anonymousMetadata });
    this.subtitleEngine = engine; this.subtitleTasks = []; this.subtitleProgress = null; this.models = { status: 'not-ready', progress: null, ready: false, error: null, languages: [] };
    this.previewResult = null; this.previewGeneration = 0; this.activeSubtitle = null; this.activePreparation = null; this.writeChain = Promise.resolve(); this.closing = false;
    this.downloads.on('change', () => this.changed()); this.downloads.on('warning', error => { this.notice = message(error); this.changed(); });
  }
  async init() {
    await fs.mkdir(this.dataDirectory, { recursive: true, mode: 0o700 });
    const saved = await readJSON(this.settingsFile, null);
    if (saved) {
      if (typeof saved.destination === 'string' && path.isAbsolute(saved.destination)) this.settings.destination = saved.destination;
      if (['best', 'p1080', 'p720', 'audio'].includes(saved.quality)) this.settings.quality = saved.quality;
      if (['none', 'chrome', 'edge', 'firefox', 'file', 'session'].includes(saved.browser)) this.settings.browser = saved.browser;
      if (typeof saved.cookiesFile === 'string' && path.isAbsolute(saved.cookiesFile)) this.settings.cookiesFile = saved.cookiesFile;
      if (saved.style) this.settings.style = style(saved.style);
    }
    await this.downloads.init();
    await this.downloads.setOptions({ downloadDirectory: this.settings.destination, quality: this.settings.quality, authentication: this.authentication(false) });
    const module = await import(pathToFileURL(path.join(__dirname, 'subtitles/engine.mjs')).href);
    this.engineModule = module;
    if (!this.subtitleEngine) this.subtitleEngine = module.createSubtitleEngine({ tools: this.tools, modelDirectory: path.join(this.dataDirectory, 'models') });
    this.models.languages = this.subtitleEngine.languages || module.LANGUAGES || [];
    const rows = await readJSON(this.subtitlesFile, []); if (!Array.isArray(rows) || rows.length > 200) throw new Error('字幕历史记录无法读取，原文件已保留。');
    this.subtitleTasks = rows;
    for (const task of this.subtitleTasks) {
      const recovered = await recoverSubtitleTask(task);
      if (recovered) { task.result = recovered; task.status = 'completed'; task.error = null; }
      else if (ACTIVE.has(task.status)) { task.status = 'interrupted'; task.error = '上次处理已中断，可点击再次处理。'; }
      else if (task.status === 'completed') { task.status = 'failed'; task.error = '导出的文件已移动或删除，请重新处理。'; }
    }
    await this.refreshModels(); await this.persistSubtitles(); this.changed(); return this;
  }
  authentication(strict = true) {
    if (this.settings.browser === 'session') return { type: 'session' };
    if (this.settings.browser === 'file') {
      if (!this.settings.cookiesFile) { if (strict) throw new Error('请先选择 Cookie 文件。'); return { type: 'none' }; }
      return { type: 'file', path: this.settings.cookiesFile };
    }
    return this.settings.browser === 'none' ? { type: 'none' } : { type: 'browser', browser: this.settings.browser };
  }
  snapshot() {
    return copy({ settings: this.settings, downloads: this.downloads.snapshot().tasks, preview: this.previewResult, previewing: this.downloads.snapshot().previewing,
      subtitles: this.subtitleTasks, subtitleProgress: this.subtitleProgress, models: this.models, toolsReady: this.toolsReady !== false, version: this.version, notice: this.notice || null });
  }
  changed() { if (!this.closing) this.emit('change', this.snapshot()); }
  async saveSettings(value = {}) {
    if ('destination' in value) { if (!path.isAbsolute(value.destination) || value.destination.includes('\0')) throw new Error('请选择有效保存目录。'); this.settings.destination = value.destination; }
    if ('quality' in value) { if (!['best', 'p1080', 'p720', 'audio'].includes(value.quality)) throw new Error('清晰度选项无效。'); this.settings.quality = value.quality; }
    if ('browser' in value) { if (!['none', 'chrome', 'edge', 'firefox', 'file', 'session'].includes(value.browser)) throw new Error('浏览器选项无效。'); this.settings.browser = value.browser; }
    if ('cookiesFile' in value) { if (value.cookiesFile && !path.isAbsolute(value.cookiesFile)) throw new Error('请选择有效 Cookie 文件。'); this.settings.cookiesFile = value.cookiesFile; }
    if ('style' in value) this.settings.style = style(value.style);
    await atomicJSON(this.settingsFile, this.settings); await this.downloads.setOptions({ downloadDirectory: this.settings.destination, quality: this.settings.quality, authentication: this.authentication(false) }); this.changed(); return this.snapshot();
  }
  async preview({ text = '' } = {}) {
    const generation = ++this.previewGeneration; this.previewResult = null; this.changed();
    const result = await this.downloads.preview(text, { authentication: this.authentication() });
    if (generation === this.previewGeneration) { const { title, duration, extractor, availableHeights, isLive, id } = result; this.previewResult = { title, duration, extractor, availableHeights, isLive, id }; this.changed(); }
    return this.previewResult;
  }
  async addDownloads({ text = '' } = {}) {
    const links = parseShareLinks(text); if (!links.length) throw new Error('没有找到有效视频链接。'); if (links.length > 50) throw new Error('每次最多添加 50 条链接。');
    const ids = []; for (const link of links) ids.push(await this.downloads.add(link, { quality: this.settings.quality, directory: this.settings.destination, authentication: this.authentication() })); return ids;
  }
  async retryDownload(id) { return this.downloads.retry(id, { authentication: this.authentication() }); }
  async persistSubtitles() { const rows = copy(this.subtitleTasks.slice(0, 200)); this.writeChain = this.writeChain.catch(() => {}).then(() => atomicJSON(this.subtitlesFile, rows)); return this.writeChain; }
  async refreshModels() {
    const status = await this.subtitleEngine.modelsStatus();
    this.models = { ...this.models, ...status, ready: status.ready === true, status: status.ready ? 'ready' : 'not-ready', error: null }; this.changed(); return this.models;
  }
  async prepareModels({ source, target } = {}) {
    if (this.activePreparation || this.activeSubtitle) throw new Error('请先完成或取消当前字幕任务。');
    const controller = new AbortController(); const active = { controller, promise: null }; this.activePreparation = active;
    this.models = { ...this.models, status: 'downloading', error: null, progress: { fraction: 0 } }; this.changed();
    active.promise = (async () => {
      try { await this.subtitleEngine.prepareModels({ source, target, signal: controller.signal, onProgress: progress => { this.models.progress = progress; this.changed(); } }); await this.refreshModels(); }
      catch (e) { this.models.status = controller.signal.aborted ? 'not-ready' : 'failed'; this.models.error = message(e); this.changed(); throw e; }
      finally { if (this.activePreparation === active) this.activePreparation = null; }
    })(); return active.promise;
  }
  cancelModelPreparation() { this.activePreparation?.controller.abort(); }
  async startSubtitle(request) {
    if (this.activeSubtitle || this.activePreparation) throw new Error('请先完成或取消当前处理。');
    const input = request.input || request.inputPath; if (typeof input !== 'string' || !path.isAbsolute(input)) throw new Error('请先选择一个视频。');
    const s = await fs.stat(input); if (!s.isFile() || s.size === 0) throw new Error('所选视频不存在或为空。');
    const validated = { input, source: request.source, target: request.target, textMode: request.textMode || 'bilingual', videoMode: request.videoMode || 'burned', style: style(request.style || this.settings.style) };
    if (!['original', 'translated', 'bilingual'].includes(validated.textMode) || !['none', 'soft', 'burned'].includes(validated.videoMode)) throw new Error('字幕输出选项无效。');
    const id = crypto.randomUUID();
    const engineRequest = this.engineModule.validateRequest({ id, inputPath: input, outputDirectory: path.join(this.settings.destination, '字幕'), sourceLanguage: validated.source, targetLanguage: validated.target, textMode: validated.textMode, outputMode: { none: 'srt', soft: 'soft', burned: 'burn' }[validated.videoMode], bilingual: validated.textMode === 'bilingual', style: validated.style });
    const expectedDirectory = this.engineModule.outputDirectoryFor(engineRequest);
    const task = { id, title: path.basename(input), request: validated, engineRequest, expectedDirectory, status: 'running', progress: null, createdAt: new Date().toISOString(), error: null, result: null };
    this.subtitleTasks.unshift(task); this.subtitleTasks = this.subtitleTasks.slice(0, 200); await this.persistSubtitles();
    const controller = new AbortController(); const active = { id, controller, promise: null }; this.activeSubtitle = active; this.changed();
    active.promise = (async () => {
      try {
        const result = await this.subtitleEngine.run(engineRequest, { signal: controller.signal, onProgress: progress => { task.progress = progress; this.subtitleProgress = { ...progress, taskId: id }; this.changed(); } });
        task.result = result; task.status = 'completed'; task.completedAt = new Date().toISOString(); task.progress = { fraction: 1, detail: '处理完成' };
      } catch (e) { task.status = controller.signal.aborted ? 'cancelled' : 'failed'; task.error = message(e); }
      finally { if (this.activeSubtitle === active) this.activeSubtitle = null; this.subtitleProgress = null; await this.persistSubtitles(); this.changed(); }
    })(); active.promise.catch(error => { this.notice = message(error); this.changed(); }); return id;
  }
  cancelSubtitle() { this.activeSubtitle?.controller.abort(); }
  async retrySubtitle(id) { const task = this.subtitleTasks.find(x => x.id === id); if (!task) throw new Error('未找到字幕记录。'); return this.startSubtitle(task.request); }
  allowedFiles() {
    return new Set([...this.downloads.snapshot().tasks.flatMap(x => [x.filePath].filter(Boolean)), ...this.subtitleTasks.flatMap(x => [x.request?.input, ...(x.result?.files || [])].filter(Boolean))].map(p => path.resolve(p)));
  }
  async close() {
    this.closing = true; this.activeSubtitle?.controller.abort(); this.activePreparation?.controller.abort();
    await Promise.allSettled([this.downloads.close(), this.activeSubtitle?.promise, this.activePreparation?.promise]); await this.persistSubtitles();
  }
}
async function recoverSubtitleTask(task) {
  try {
    if (!task.engineRequest || !task.expectedDirectory || task.engineRequest.id !== task.id || !path.isAbsolute(task.expectedDirectory)) return null;
    const directory = task.expectedDirectory;
    const lstat = await fs.lstat(directory); if (!lstat.isDirectory() || lstat.isSymbolicLink()) return null;
    const receiptPath = path.join(directory, 'completion.json');
    const receipt = await readJSON(receiptPath, null, 2000000);
    if (!receipt || receipt.schemaVersion !== 1 || receipt.id !== task.id || !isDeepStrictEqual(receipt.request, task.engineRequest) || !Array.isArray(receipt.files) || receipt.files.length < 1 || receipt.files.length > 3) return null;
    const files = [];
    for (const file of receipt.files) {
      if (typeof file.name !== 'string' || path.basename(file.name) !== file.name || !['.srt','.mp4','.mkv'].includes(path.extname(file.name)) || !Number.isSafeInteger(file.size) || file.size <= 0) return null;
      const absolute = path.join(directory, file.name); const stat = await fs.lstat(absolute);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== file.size) return null; files.push(absolute);
    }
    return { directory, files, receiptPath, cueCount: receipt.cueCount, duration: receipt.duration, style: receipt.request.style, peakMemoryBytes: receipt.peakMemoryBytes };
  } catch { return null; }
}
module.exports = { FeatherController, message, style, readJSON, recoverSubtitleTask };
