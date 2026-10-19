'use strict';
const { app, BrowserWindow, ipcMain, dialog, shell, session } = require('electron');
const path = require('node:path');
const fs = require('node:fs/promises');
const os = require('node:os');
const { fileURLToPath, pathToFileURL } = require('node:url');
const { FeatherController, message } = require('./controller.cjs');
const { runProcess } = require('./core');
const { createSiteSession } = require('./site-session.cjs');
const { UpdateService, applicationBusy } = require('./update-service.cjs');
if (process.env.FEATHER_TEST_DATA) app.setPath('userData', path.resolve(process.env.FEATHER_TEST_DATA));
app.setName('飞羽下载 Windows');
const lock = app.requestSingleInstanceLock();
if (!lock) app.quit();
let window, controller, siteSession, updates, closing = false, shutdownDone = false, emitTimer = null, heartbeatTimer, lastHeartbeat = Date.now(), memoryOverAt = 0;
const selectedPaths = new Set();
const root = path.resolve(__dirname, '..');
function tools() {
  if (process.platform === 'darwin' && !app.isPackaged) {
    const dir = path.resolve(root, '../work/vendor');
    return { ytDlp: path.join(dir,'yt-dlp'), ffmpeg: path.join(dir,'ffmpeg'), ffprobe: path.join(dir,'ffprobe'), deno: path.join(dir,'deno'), whisper: process.env.FEATHER_WHISPER || path.resolve(root,'../work/windows-validation/whisper-build/bin/whisper-cli'), node: process.execPath };
  }
  const dir = app.isPackaged ? path.join(process.resourcesPath, 'tools') : path.join(root, 'vendor/win-x64');
  return { ytDlp: path.join(dir,'yt-dlp.exe'), ffmpeg: path.join(dir,'ffmpeg.exe'), ffprobe: path.join(dir,'ffprobe.exe'), deno: path.join(dir,'deno.exe'), whisper: path.join(dir,'whisper','whisper-cli.exe'), fonts: path.join(dir,'fonts'), node: process.execPath };
}
async function shutdown(reason) {
  if (closing) return; closing = true; updates?.cancelForShutdown(); clearInterval(heartbeatTimer); clearTimeout(emitTimer);
  const deadline = setTimeout(() => app.exit(1), 7000); deadline.unref();
  try { siteSession?.close(); await controller?.close(); } finally { shutdownDone = true; clearTimeout(deadline); app.quit(); }
}
function sendState() {
  if (emitTimer || closing) return;
  emitTimer = setTimeout(() => { emitTimer = null; if (window && !window.isDestroyed()) window.webContents.send('feather:state', snapshot()); }, 150);
}
function snapshot() { return { ...controller.snapshot(), update: updates?.snapshot() }; }
async function prepareUpdateInstall() {
  closing = true; clearInterval(heartbeatTimer); clearTimeout(emitTimer); emitTimer = null;
  try { siteSession?.close(); await controller.close(); shutdownDone = true; }
  catch (error) { closing = false; throw error; }
}
function validSender(event) {
  if (!window || event.sender !== window.webContents || event.senderFrame !== window.webContents.mainFrame || !event.senderFrame.url.startsWith(pathToFileURL(path.join(root, 'renderer/')).href)) throw new Error('请求来源无效。');
}
function call(name, fn) { ipcMain.handle(`feather:${name}`, async (event, ...args) => { validSender(event); try { return await (name === 'getState' || ['checkUpdate','downloadUpdate','cancelUpdate','installUpdate'].includes(name) ? fn(...args) : updates.runActivity(() => fn(...args))); } catch (e) { throw new Error(message(e)); } }); }
function fileAllowed(value) {
  if (typeof value !== 'string' || !path.isAbsolute(value) || value.includes('\0')) throw new Error('文件路径无效。');
  const absolute = path.resolve(value);
  if (!selectedPaths.has(absolute) && !controller.allowedFiles().has(absolute)) throw new Error('请先从任务列表或文件选择器选择文件。');
  return absolute;
}
async function pick(properties, filters) {
  const result = await dialog.showOpenDialog(window, { properties, filters });
  const value = result.canceled ? null : result.filePaths[0]; if (value) selectedPaths.add(path.resolve(value)); return value;
}
let runtimeCheck;
async function ensureSubtitleRuntime() {
  if (process.platform !== 'win32') return;
  if (runtimeCheck) return runtimeCheck;
  runtimeCheck = (async () => {
    try {
      const check = await runProcess({ executable: tools().whisper, args: ['--help'], limits: { totalTimeoutMs: 15000, preparationTimeoutMs: 15000, maximumOutputBytes: 262144, maximumStandardErrorBytes: 262144, maximumMemoryBytes: 256 * 1024 * 1024 } });
      if (check.exitCode !== 0) throw new Error('native runtime unavailable');
      if (!require('onnxruntime-node').InferenceSession) throw new Error('translation runtime unavailable');
    } catch {
      const result = await dialog.showMessageBox(window, { type: 'info', title: '准备本机翻译环境', message: '视频翻译组件暂时无法启动。', detail: '常见原因是缺少 Microsoft Visual C++ 64 位运行库。可先从微软官网下载并安装最新 x64 版本，然后重开飞羽。程序不会替你执行安装或接受协议。若已经安装，请检查安全软件是否隔离了程序组件。', buttons: ['打开微软官方下载页', '暂不处理'], defaultId: 0, cancelId: 1 });
      if (result.response === 0) await shell.openExternal('https://learn.microsoft.com/zh-cn/cpp/windows/latest-supported-vc-redist');
      throw new Error('请准备好 Microsoft Visual C++ x64 运行库后，再重试翻译与字幕。');
    }
  })();
  try { return await runtimeCheck; } catch (error) { runtimeCheck = null; throw error; }
}
function checkTranslationMemory(request) {
  if (process.platform !== 'win32' || request.textMode === 'original' || request.source === request.target) return;
  if (os.totalmem() < 7 * 1024 ** 3 || os.freemem() < 3.5 * 1024 ** 3) throw new Error('本机翻译需要至少 8 GB 内存且当前可用内存不少于 3.5 GB。请先释放一些内存后重试；推荐 16 GB 或更多内存。');
}
async function createWindow() {
  window = new BrowserWindow({ title: '飞羽下载 · Windows 版', width: 1240, height: 860, minWidth: 1000, minHeight: 690, backgroundColor: '#FFFFFF', icon: path.join(root,'assets/icon.png'), show: false,
    webPreferences: { preload: path.join(__dirname,'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true, webSecurity: true, devTools: !app.isPackaged } });
  window.removeMenu(); window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault()); window.webContents.on('will-attach-webview', event => event.preventDefault());
  window.webContents.on('render-process-gone', () => { if (!closing) void shutdown('renderer exited'); });
  window.on('close', event => { if (!shutdownDone) { event.preventDefault(); void shutdown('window closed'); } });
  window.once('ready-to-show', () => { window.show(); lastHeartbeat = Date.now(); });
  await window.loadFile(path.join(root,'renderer/index.html'));
  heartbeatTimer = setInterval(() => {
    if (closing || !window || window.isDestroyed() || !window.isVisible()) return;
    window.webContents.send('feather:heartbeat');
    const metrics = app.getAppMetrics(); const ownKB = metrics.reduce((sum,x) => sum + (x.memory?.workingSetSize || 0), 0);
    if (ownKB > 1024 * 1024) memoryOverAt ||= Date.now(); else memoryOverAt = 0;
    if (Date.now() - lastHeartbeat > 20000 || (memoryOverAt && Date.now() - memoryOverAt > 15000)) void shutdown('interface resource guard');
  }, 2000); heartbeatTimer.unref();
}
app.on('second-instance', () => { if (window) { if (window.isMinimized()) window.restore(); window.show(); window.focus(); } });
app.on('before-quit', event => { if (!shutdownDone && controller) { event.preventDefault(); void shutdown('quit'); } });
app.on('window-all-closed', () => { if (shutdownDone) app.quit(); else if (!closing) void shutdown('all windows closed'); });
app.whenReady().then(async () => {
  if (!lock) return;
  session.defaultSession.setPermissionRequestHandler((_webContents, _permission, callback) => callback(false));
  session.defaultSession.setPermissionCheckHandler(() => false);
  siteSession = createSiteSession({ BrowserWindow, session, parent: () => window, onBusyChange: sendState });
  controller = new FeatherController({ dataDirectory: app.getPath('userData'), downloadDirectory: path.join(app.getPath('downloads'),'飞羽下载'), tools: tools(), version: app.getVersion(), sessionAuthentication: sourceURL => siteSession.prepare(sourceURL), sessionMetadata: (sourceURL, options) => siteSession.metadata(sourceURL, options), anonymousMetadata: (sourceURL, options) => siteSession.anonymousMetadata(sourceURL, options) });
  await controller.init();
  const t = tools(); const required = [t.ytDlp,t.ffmpeg,t.ffprobe,t.deno]; controller.toolsReady = (await Promise.all(required.map(p => fs.stat(p).then(s => s.isFile()).catch(() => false)))).every(Boolean);
  const updateSupported = process.platform === 'win32' && app.isPackaged;
  updates = new UpdateService({ updater: updateSupported ? require('electron-updater').autoUpdater : null, version: app.getVersion(), supported: updateSupported, isBusy: () => applicationBusy(controller, siteSession), prepareInstall: prepareUpdateInstall });
  updates.on('change', () => { if (window && !window.isDestroyed()) window.webContents.send('feather:update', updates.snapshot()); });
  controller.on('change', sendState);
  ipcMain.on('feather:heartbeat-reply', event => { if (window && event.sender === window.webContents) lastHeartbeat = Date.now(); });
  call('getState', snapshot);
  call('checkUpdate', () => updates.check()); call('downloadUpdate', () => updates.download());
  call('cancelUpdate', () => updates.cancel()); call('installUpdate', () => updates.install());
  call('openWebsite', async text => { if (controller.settings.browser !== 'session') throw new Error('请先选择「应用内网站会话」。'); return siteSession.open(text); });
  call('preview', options => controller.preview(options)); call('addDownloads', options => controller.addDownloads(options));
  call('retryDownload', id => controller.retryDownload(id)); call('cancelDownload', id => controller.downloads.cancel(id)); call('removeDownload', id => controller.downloads.remove(id));
  call('saveSettings', value => controller.saveSettings(value));
  call('chooseDownloadDirectory', async () => { const p = await pick(['openDirectory','createDirectory']); if (p) await controller.saveSettings({ destination:p }); return p; });
  call('chooseCookiesFile', async () => { const p = await pick(['openFile'],[{name:'Cookie 文本',extensions:['txt','cookies']}]); if (p) await controller.saveSettings({cookiesFile:p,browser:'file'}); return p; });
  call('chooseVideo', () => pick(['openFile'],[{name:'视频文件',extensions:['mp4','mkv','mov','webm','avi','m4v','wmv','flv']} ]));
  call('revealFile', p => { shell.showItemInFolder(fileAllowed(p)); return true; });
  call('openFile', async p => { const error = await shell.openPath(fileAllowed(p)); if (error) throw new Error('系统无法打开这个文件，请在保存目录中手动打开。'); return true; });
  call('openDownloadDirectory', async () => { await fs.mkdir(controller.settings.destination,{recursive:true}); const error = await shell.openPath(controller.settings.destination); if(error) throw new Error('无法打开保存文件夹。'); return true; });
  call('startSubtitle', async request => { request.input = fileAllowed(request.input || request.inputPath); checkTranslationMemory(request); await ensureSubtitleRuntime(); return controller.startSubtitle(request); });
  call('retrySubtitle', async id => { const task = controller.subtitleTasks.find(x => x.id === id); if (!task) throw new Error('未找到字幕记录。'); checkTranslationMemory(task.request); await ensureSubtitleRuntime(); return controller.retrySubtitle(id); }); call('cancelSubtitle', () => controller.cancelSubtitle());
  call('prepareModels', async options => { await ensureSubtitleRuntime(); return controller.prepareModels(options); }); call('cancelModelPreparation', () => controller.cancelModelPreparation());
  await createWindow();
}).catch(error => { dialog.showErrorBox('飞羽下载未能启动',message(error)); app.exit(1); });
