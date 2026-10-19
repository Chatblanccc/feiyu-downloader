'use strict';
const { EventEmitter } = require('node:events');

const RELEASES = Object.freeze({ provider: 'github', owner: 'Chatblanccc', repo: 'feiyu-downloader', private: false });
const BUSY_MESSAGE = '请先完成或取消下载、字幕和语言资源任务，并关闭应用内网站会话，再点击「重启并更新」。';
function updateError(error) {
  const code = String(error?.code || '');
  if (/SHA|CHECKSUM|SIGNATURE/i.test(code) || /sha512|checksum|signature|hash mismatch/i.test(String(error?.message || ''))) return '更新包未通过完整性或签名检查，已停止更新。请重新检查更新后再试。';
  if (/CHANNEL_FILE_NOT_FOUND|LATEST_VERSION_NOT_FOUND|NO_PUBLISHED_VERSIONS|INVALID_RELEASE_FEED/.test(code)) return 'GitHub 上暂时没有可用的 Windows 更新包，请稍后再试。';
  if (/ENOENT|INVALID_CONFIGURATION/.test(code)) return '更新配置尚未准备好，请从 GitHub 安装完整的 Windows 版本后再试。';
  return '暂时无法连接 GitHub 或下载更新，请检查网络后重试。';
}
function releaseDetails(info) {
  if (!info || !/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(info.version)) throw new Error('invalid update metadata');
  const file = Array.isArray(info.files) && info.files.find(item => typeof item.url === 'string' && /^[A-Za-z0-9._-]+\.exe$/i.test(item.url));
  if (!file || !/^[A-Za-z0-9+/]{86}==$/.test(file.sha512 || '') || !Number.isSafeInteger(file.size) || file.size <= 0 || info.packages) throw Object.assign(new Error('invalid update checksum or full installer metadata'), { code: 'ERR_UPDATER_CHECKSUM' });
  // Release notes are untrusted text. The renderer uses textContent, never HTML.
  const rawNotes = Array.isArray(info.releaseNotes) ? info.releaseNotes.slice(0, 100).map(item => `${item.version || ''}\n${item.note || ''}`).join('\n\n') : String(info.releaseNotes || '本次发布未提供更新说明。');
  const notes = rawNotes.slice(0, 16000).replace(/<(?:script|style)\b[^>]*>[\s\S]*?<\/(?:script|style)>/gi, '').replace(/<br\s*\/?\s*>|<\/(?:p|li|h[1-6])>/gi, '\n').replace(/<[^>]*>/g, '').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&').trim();
  return { version: info.version, size: file.size, notes };
}
function applicationBusy(controller, siteSession, pendingActivities = 0) {
  const downloads = controller?.downloads?.snapshot();
  return !!(pendingActivities || downloads?.activeCount || downloads?.previewing || downloads?.tasks?.some(task => !['completed', 'failed', 'cancelled', 'canceled', 'interrupted'].includes(task.status)) || controller?.activeSubtitle || controller?.activePreparation || siteSession?.isBusy());
}

class UpdateService extends EventEmitter {
  constructor({ updater, version, supported = true, isBusy = () => false, prepareInstall = async () => {} } = {}) {
    super();
    this.updater = updater; this.isBusy = isBusy; this.prepareInstall = prepareInstall;
    this.acceptingInstall = false; this.pendingActivities = 0; this.checkPromise = null; this.downloadPromise = null; this.installPromise = null; this.token = null;
    this.state = { status: supported && updater ? 'idle' : 'unavailable', currentVersion: version, version: null, size: null, notes: '', progress: null, error: null };
    if (!supported || !updater) return;
    updater.autoDownload = false; updater.autoInstallOnAppQuit = false;
    updater.allowPrerelease = false; updater.allowDowngrade = false;
    updater.disableWebInstaller = true; updater.disableDifferentialDownload = true;
    // This is a public provider: no token or credentials are sent by the app.
    updater.setFeedURL(RELEASES);
    updater.on('download-progress', progress => {
      if (this.state.status !== 'downloading') return;
      const transferred = Math.max(0, Number(progress.transferred) || 0), total = Math.max(0, Number(progress.total) || this.state.size || 0);
      this.set({ progress: { transferred, total, percent: total ? Math.min(100, transferred / total * 100) : 0, bytesPerSecond: Math.max(0, Number(progress.bytesPerSecond) || 0) } });
    });
    // Promise rejection handles check/download errors; explicit installation can
    // also fail synchronously or asynchronously through this event.
    updater.on('error', () => {
      if (this.acceptingInstall) this.set({ status: 'error', error: '更新安装未能启动，请关闭并重新打开飞羽下载后重试。' });
    });
  }
  snapshot() { return structuredClone({ ...this.state, installBlocked: this.state.status === 'downloaded' && this.busy(), busyMessage: BUSY_MESSAGE }); }
  busy() { return !!(this.pendingActivities || this.isBusy()); }
  set(value) { Object.assign(this.state, value); this.emit('change', this.snapshot()); }
  assertAvailable() {
    if (!this.updater || this.state.status === 'unavailable') throw new Error('检查更新仅适用于安装后的 Windows 版本，请从 GitHub 安装完整版本。');
    if (this.acceptingInstall) throw new Error('正在保存并安装更新，请稍候。');
  }
  // Reserve admission synchronously, before an IPC handler's first await. This
  // includes runtime preparation and writes that have not reached a job yet.
  runActivity(operation) {
    if (this.acceptingInstall) return Promise.reject(new Error('正在准备重启更新，请更新完成后再开始新任务。'));
    this.pendingActivities++;
    return Promise.resolve().then(operation).finally(() => { this.pendingActivities--; this.emit('change', this.snapshot()); });
  }
  check() {
    this.assertAvailable();
    if (this.checkPromise) return this.checkPromise;
    if (this.downloadPromise || this.state.status === 'downloaded') return Promise.resolve(this.snapshot());
    this.token = null;
    this.set({ status: 'checking', error: null, progress: null, version: null, size: null, notes: '' });
    this.checkPromise = Promise.resolve().then(() => this.updater.checkForUpdates()).then(result => {
      if (!result) throw Object.assign(new Error('missing config'), { code: 'ERR_UPDATER_INVALID_CONFIGURATION' });
      if (!result.isUpdateAvailable) this.set({ status: 'up-to-date' });
      else {
        const details = releaseDetails(result.updateInfo);
        if (!result.cancellationToken || typeof result.cancellationToken.cancel !== 'function') throw new Error('missing cancellation token');
        this.token = result.cancellationToken;
        this.set({ ...details, status: 'available' });
      }
      return this.snapshot();
    }).catch(error => { this.set({ status: 'error', error: updateError(error) }); return this.snapshot(); }).finally(() => { this.checkPromise = null; });
    return this.checkPromise;
  }
  download() {
    this.assertAvailable();
    if (this.downloadPromise) return this.downloadPromise;
    if (this.state.status !== 'available' || !this.token) throw new Error('请先检查更新，再下载新版本。');
    const token = this.token;
    this.set({ status: 'downloading', progress: { transferred: 0, total: this.state.size, percent: 0, bytesPerSecond: 0 }, error: null });
    this.downloadPromise = Promise.resolve().then(() => this.updater.downloadUpdate(token)).then(files => {
      if (token.cancelled) { this.set({ status: 'cancelled', progress: null }); return this.snapshot(); }
      if (!Array.isArray(files) || !files.length) throw new Error('missing downloaded installer');
      // electron-updater resolves only after its built-in SHA512 verification.
      this.set({ status: 'downloaded', progress: null }); return this.snapshot();
    }).catch(error => {
      if (token.cancelled) this.set({ status: 'cancelled', progress: null, error: null });
      else this.set({ status: 'error', progress: null, error: updateError(error) });
      return this.snapshot();
    }).finally(() => { this.downloadPromise = null; });
    return this.downloadPromise;
  }
  cancel() {
    this.assertAvailable();
    if (this.state.status === 'downloading') { this.set({ status: 'cancelling' }); this.token?.cancel(); }
    return this.snapshot();
  }
  install() {
    this.assertAvailable();
    if (this.state.status !== 'downloaded') throw new Error('请先下载并校验更新包。');
    if (this.busy()) { this.set({ error: BUSY_MESSAGE }); return Promise.resolve(this.snapshot()); }
    // Keep the gate closed through cleanup and installation. Failure after
    // cleanup requires reopening the app, since its controllers are closed.
    this.acceptingInstall = true;
    this.set({ status: 'installing', error: null });
    this.installPromise = Promise.resolve().then(() => this.prepareInstall()).then(() => {
      if (this.state.status === 'installing') this.updater.quitAndInstall(true, true);
      return this.snapshot();
    }).catch(() => {
      this.set({ status: 'error', error: '保存状态或启动更新未能完成，请关闭并重新打开飞羽下载后重试。' }); return this.snapshot();
    });
    return this.installPromise;
  }
  cancelForShutdown() { if (this.downloadPromise) this.token?.cancel(); }
}
module.exports = { UpdateService, RELEASES, BUSY_MESSAGE, updateError, releaseDetails, applicationBusy };
