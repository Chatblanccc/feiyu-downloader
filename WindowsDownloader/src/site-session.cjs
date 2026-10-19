'use strict';
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { DownloadError, parseShareLinks } = require('./core/protocol');
const { readDouyinPage, douyinInfo, supportsDouyinURL, douyinVideoID } = require('./douyin.cjs');

// Short-link hosts and their destination sites share one explicitly selected session.
const SITE_GROUPS = [
  ['douyin.com', 'iesdouyin.com'], ['b23.tv', 'bilibili.com'], ['youtu.be', 'youtube.com'],
  ['x.com', 'twitter.com', 't.co'], ['xiaohongshu.com', 'xhslink.com'],
  ['tiktok.com'], ['kuaishou.com', 'gifshow.com']
];
const within = (host, domain) => host === domain || host.endsWith('.' + domain);
function browserUserAgent(value) {
  // Electron adds the app name, which can be Chinese. HTTP libraries used by
  // yt-dlp encode headers as Latin-1, so forward only the browser's ASCII UA.
  return String(value).replace(/\s(?:Electron|feiyu-downloader|飞羽下载(?:\s*Windows)?)\/\S+/gi, '').replace(/[^\x20-\x7e]/g, '');
}
function siteURL(text) {
  const value = parseShareLinks(text)[0];
  if (!value) throw new DownloadError('noURL');
  return new URL(value);
}
function cookieFileContent(cookies, sourceURL, now = Date.now() / 1000) {
  const host = siteURL(sourceURL).hostname.toLowerCase();
  const group = SITE_GROUPS.find(domains => domains.some(domain => within(host, domain)));
  const rows = ['# Netscape HTTP Cookie File'];
  for (const cookie of cookies) {
    const domain = String(cookie.domain || ''), bare = domain.replace(/^\./, '').toLowerCase();
    if (!bare || /[\s\/#:]/.test(bare)) continue;
    if (!(group ? group.some(site => within(bare, site)) : within(host, bare))) continue;
    if (Number.isFinite(cookie.expirationDate) && cookie.expirationDate <= now) continue;
    const fields = [domain, domain.startsWith('.') && !cookie.hostOnly ? 'TRUE' : 'FALSE', cookie.path || '/', cookie.secure ? 'TRUE' : 'FALSE', cookie.session || !Number.isFinite(cookie.expirationDate) ? '0' : String(Math.floor(cookie.expirationDate)), cookie.name, cookie.value];
    if (fields.some(field => typeof field !== 'string' || /[\r\n\t\0]/.test(field))) continue;
    if (cookie.httpOnly) fields[0] = '#HttpOnly_' + fields[0];
    rows.push(fields.join('\t'));
  }
  if (rows.length === 1) throw new DownloadError('missingSiteSession');
  const content = rows.join('\n') + '\n';
  if (Buffer.byteLength(content) > 16 * 1024 * 1024) throw new DownloadError('invalidCookieFile');
  return content;
}

function createSiteSession({ BrowserWindow, session, parent }) {
  const websiteSession = session.fromPartition('persist:feiyu-websites');
  websiteSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  websiteSession.setPermissionCheckHandler(() => false);
  websiteSession.on('will-download', event => event.preventDefault());
  const userAgent = browserUserAgent(websiteSession.getUserAgent());
  websiteSession.setUserAgent(userAgent);
  let websiteWindow;
  const extractionWindows = new Set();
  function navigationAllowed(value) {
    try { const url = new URL(value); return ['https:', 'http:'].includes(url.protocol) && !url.username && !url.password; }
    catch { return false; }
  }
  async function open(text) {
    const url = siteURL(text).href;
    if (!websiteWindow || websiteWindow.isDestroyed()) {
      websiteWindow = new BrowserWindow({ width: 1120, height: 800, title: '飞羽 · 网站会话（确认视频可以播放后，关闭此窗口返回下载）', parent: parent(),
        webPreferences: { session: websiteSession, contextIsolation: true, nodeIntegration: false, sandbox: true, webSecurity: true, devTools: false } });
      websiteWindow.removeMenu();
      websiteWindow.webContents.on('will-navigate', (event, value) => { if (!navigationAllowed(value)) event.preventDefault(); });
      websiteWindow.webContents.on('will-redirect', (event, value) => { if (!navigationAllowed(value)) event.preventDefault(); });
      websiteWindow.webContents.on('will-attach-webview', event => event.preventDefault());
      websiteWindow.webContents.setWindowOpenHandler(({ url: value }) => {
        if (navigationAllowed(value)) void websiteWindow.loadURL(value).catch(() => {});
        return { action: 'deny' };
      });
    }
    websiteWindow.show(); websiteWindow.focus();
    try { await websiteWindow.loadURL(url); }
    catch (error) { if (error.code !== 'ERR_ABORTED') throw new Error('视频网站暂时无法打开，请检查网络后重试。'); }
    return true;
  }
  async function prepare(sourceURL) {
    // Export only the requested site's cookies from our own session. Never touch Chrome/Edge databases.
    const content = cookieFileContent(await websiteSession.cookies.get({}), sourceURL);
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'FeiyuSiteCookies-'));
    const filename = path.join(directory, 'cookies.txt');
    try { await fs.writeFile(filename, content, { mode: 0o600 }); }
    catch (error) { await fs.rm(directory, { recursive: true, force: true }); throw error; }
    return { args: ['--no-cookies-from-browser', '--cookies', filename, '--user-agent', userAgent], cleanup: () => fs.rm(directory, { recursive: true, force: true }) };
  }
  async function metadata(sourceURL, { signal, anonymous = false } = {}) {
    const url = siteURL(sourceURL);
    if (!supportsDouyinURL(url.href)) return null;
    if (signal?.aborted) throw new DownloadError('cancelled');
    // No persist: prefix: each anonymous request starts with an empty in-memory
    // session, independent of both personal browsers and our optional login window.
    const pageSession = anonymous ? session.fromPartition('feiyu-anonymous-' + randomUUID(), { cache: false }) : websiteSession;
    if (anonymous) {
      pageSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
      pageSession.setPermissionCheckHandler(() => false);
      pageSession.setUserAgent(userAgent);
      pageSession.on('will-download', event => event.preventDefault());
    }
    let browser;
    try { browser = new BrowserWindow({ show: false, webPreferences: { session: pageSession, sandbox: true, contextIsolation: true, nodeIntegration: false, webSecurity: true, devTools: false } }); }
    catch (error) { if (anonymous) await Promise.allSettled([pageSession.clearStorageData(), pageSession.clearCache()]); throw error; }
    extractionWindows.add(browser); browser.webContents.setAudioMuted(true);
    browser.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    let targetID = douyinVideoID(url.href);
    for (const eventName of ['will-navigate', 'will-redirect']) browser.webContents.on(eventName, (event, value) => {
      if (!navigationAllowed(value) || (anonymous && (!/(^|\.)(douyin\.com|iesdouyin\.com)$/.test(new URL(value).hostname) || (targetID && douyinVideoID(value) && douyinVideoID(value) !== targetID)))) event.preventDefault();
    });
    let timer, abort;
    const guard = new Promise((_resolve, reject) => {
      timer = setTimeout(() => reject(new DownloadError(anonymous ? 'anonymousExtractionUnavailable' : 'missingSiteSession')), 35000);
      abort = () => reject(new DownloadError('cancelled'));
      signal?.addEventListener('abort', abort, { once: true });
      if (signal?.aborted) abort();
    });
    const read = async () => {
      const initialURL = targetID ? 'https://www.douyin.com/video/' + targetID : url.href;
      await browser.loadURL(initialURL).catch(error => { if (error.code !== 'ERR_ABORTED') throw new DownloadError(anonymous ? 'anonymousExtractionUnavailable' : 'missingSiteSession'); });
      if (!targetID) {
        const landedURL = browser.webContents.getURL();
        if (!supportsDouyinURL(landedURL)) throw new DownloadError('invalidMetadata');
        targetID = douyinVideoID(landedURL);
      }
      if (!targetID) throw new DownloadError('invalidMetadata');
      while (!browser.isDestroyed() && !signal?.aborted) {
        const value = await browser.webContents.executeJavaScript('(' + readDouyinPage.toString() + ')()');
        if (value && value.length <= 1024 * 1024) {
          const info = douyinInfo(value, userAgent), expected = targetID;
          if (expected && expected !== info.id) throw new DownloadError('invalidMetadata');
          return info;
        }
        await new Promise(resolve => setTimeout(resolve, 300));
      }
      throw new DownloadError('cancelled');
    };
    try { return await Promise.race([read(), guard]); }
    finally {
      clearTimeout(timer); signal?.removeEventListener('abort', abort); extractionWindows.delete(browser); if (!browser.isDestroyed()) browser.destroy();
      if (anonymous) await Promise.allSettled([pageSession.clearStorageData(), pageSession.clearCache()]);
    }
  }
  function close() { if (websiteWindow && !websiteWindow.isDestroyed()) websiteWindow.destroy(); for (const browser of extractionWindows) if (!browser.isDestroyed()) browser.destroy(); }
  return { open, prepare, metadata, anonymousMetadata: (sourceURL, options) => metadata(sourceURL, { ...options, anonymous: true }), close };
}
module.exports = { createSiteSession, cookieFileContent, siteURL, browserUserAgent };
