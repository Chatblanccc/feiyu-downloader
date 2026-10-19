'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { DownloadEngine, FINAL_PREFIX, isBrowserCookieFailure, readableFailure, authentication } = require('../src/core');
const { cookieFileContent, createSiteSession, siteURL, browserUserAgent } = require('../src/site-session.cjs');
const metadata = { exitCode: 0, stdout: JSON.stringify({ id: 'public', title: 'Public video', formats: [] }), stderr: '' };
const tools = { ytDlp: process.execPath, ffmpeg: process.execPath };
const brokenBrowser = { exitCode: 1, stderr: 'ERROR: Failed to decrypt with DPAPI. See https://example.com/help' };

test('Chinese Electron app names never reach the HTTP User-Agent used by downloads', () => {
  for (const product of ['飞羽下载Windows/0.3.2', '飞羽下载 Windows/0.3.2', '飞羽下载/0.3.2', 'feiyu-downloader/0.3.2']) {
    const value = browserUserAgent(`Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ${product} Chrome/152.0.7977.167 Safari/537.36 Electron/44.9.0`);
    assert.match(value, /Chrome\/152\.0\.7977\.167 Safari\/537\.36/);
    assert.doesNotMatch(value, /[^\x20-\x7e]|飞羽|Electron|feiyu-downloader|Windows\/0\.3\.2/);
  }
});

test('Windows cookie decryption failure retries public extraction once and downloads without re-reading the broken browser', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'FeiyuAuth-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const file = path.join(directory, '视频.mp4');
  const calls = [], warnings = [];
  const engine = new DownloadEngine({ tools, platform: 'win32', onResourceWarning: value => warnings.push(value), runner: async options => {
    calls.push(options);
    if (options.args.includes('--cookies-from-browser')) return brokenBrowser;
    assert.ok(options.args.includes('--no-cookies-from-browser'));
    assert.ok(options.args.includes('--no-cookies'));
    if (options.args.includes('--dump-single-json')) return metadata;
    await fs.writeFile(file, 'video');
    options.onLine(FINAL_PREFIX + JSON.stringify(file), 'stdout');
    return { exitCode: 0, stderr: '' };
  } });
  const auth = { type: 'browser', browser: 'chrome' };
  const info = await engine.preview('https://example.com/video', { authentication: auth });
  assert.equal(info.anonymousFallback, true);
  assert.equal((await engine.download(info, { directory, authentication: auth })).fileSize, 5);
  assert.equal(calls.length, 3);
  assert.equal(calls.filter(call => call.args.includes('--cookies-from-browser')).length, 1);
  assert.equal(warnings.length, 1);
});

test('fallback reports the actual site requirement when anonymous extraction still needs a session', async () => {
  let calls = 0;
  const engine = new DownloadEngine({ tools, platform: 'win32', runner: async () => ++calls === 1 ? brokenBrowser : { exitCode: 1, stderr: 'ERROR: [Douyin] Fresh cookies (not necessarily logged in) are needed' } });
  await assert.rejects(engine.preview('https://www.douyin.com/video/123', { authentication: { type: 'browser', browser: 'chrome' } }), error => error.code === 'processFailed' && /应用内网站会话/.test(error.message));
  assert.equal(calls, 2);
});

test('other platforms and ordinary site/network failures never trigger the Windows cookie fallback', async () => {
  for (const [platform, failure] of [['darwin', brokenBrowser], ['win32', { exitCode: 1, stderr: 'ERROR: HTTP Error 403: Forbidden' }], ['win32', { exitCode: 1, stderr: 'ERROR: Network connection failed' }]]) {
    let calls = 0;
    const engine = new DownloadEngine({ tools, platform, runner: async () => { calls++; return failure; } });
    await assert.rejects(engine.preview('https://example.com/video', { authentication: { type: 'browser', browser: 'chrome' } }));
    assert.equal(calls, 1);
  }
  assert.equal(isBrowserCookieFailure('WARNING: failed to decrypt\nERROR: network connection failed'), false);
  assert.equal(isBrowserCookieFailure('ERROR: unavailable https://example.com/failed-to-decrypt'), false);
  assert.equal(isBrowserCookieFailure('ERROR: Could not copy Chrome cookie database'), true);
  assert.match(readableFailure(brokenBrowser.stderr), /应用内网站会话/);
});

test('cancellation after cookie failure prevents a second helper from starting', async () => {
  const controller = new AbortController();
  let calls = 0;
  const engine = new DownloadEngine({ tools, platform: 'win32', runner: async () => { calls++; controller.abort(); return brokenBrowser; } });
  await assert.rejects(engine.preview('https://example.com/video', { authentication: { type: 'browser', browser: 'edge' }, signal: controller.signal }), { code: 'cancelled' });
  assert.equal(calls, 1);
});

test('site session cookies include the short link destination, exclude unrelated and expired cookies, and reject line injection', () => {
  const content = cookieFileContent([
    { domain: '.douyin.com', path: '/', name: 'session', value: 'private', secure: true, httpOnly: true, expirationDate: 2000 },
    { domain: 'www.douyin.com', path: '/', name: 'visitor', value: 'fresh', hostOnly: true, session: true },
    { domain: '.unrelated.com', name: 'secret', value: 'excluded' },
    { domain: '.douyin.com', name: 'expired', value: 'excluded', expirationDate: 900 },
    { domain: '.douyin.com', name: 'injection', value: 'bad\nrow' }
  ], 'https://v.douyin.com/example/', 1000);
  assert.match(content, /#HttpOnly_\.douyin.com\tTRUE\t\/\tTRUE\t2000\tsession\tprivate/);
  assert.match(content, /www.douyin.com\tFALSE\t\/\tFALSE\t0\tvisitor\tfresh/);
  assert.doesNotMatch(content, /unrelated|excluded|injection/);
  assert.throws(() => cookieFileContent([{ domain: '.notexample.com', name: 'a', value: 'b' }], 'https://example.com/'), { code: 'missingSiteSession' });
  assert.throws(() => siteURL('file:///C:/private'), { code: 'noURL' });
});

test('explicit site-session selection uses a temporary scoped jar and cleans it after helper failure', async () => {
  let jar, cookieReads = 0;
  const fakeSession = {
    setPermissionRequestHandler() {}, setPermissionCheckHandler() {}, on() {}, setUserAgent() {},
    getUserAgent: () => 'Mozilla/5.0 Chrome/152.0.0.0 feiyu-downloader/0.3.0 Electron/44.9.0',
    cookies: { get: async () => { cookieReads++; return [{ domain: '.example.com', name: 'session', value: 'test-only', session: true }]; } }
  };
  const service = createSiteSession({ session: { fromPartition: () => fakeSession }, parent: () => null });
  const engine = new DownloadEngine({ tools, sessionAuthentication: url => service.prepare(url), runner: async options => {
    jar = options.args[options.args.indexOf('--cookies') + 1];
    assert.match(await fs.readFile(jar, 'utf8'), /test-only/);
    assert.ok(options.args.includes('--no-cookies-from-browser'));
    assert.doesNotMatch(options.args[options.args.indexOf('--user-agent') + 1], /Electron|feiyu-downloader/);
    return { exitCode: 1, stderr: 'ERROR: network connection failed' };
  } });
  assert.deepEqual(authentication({ type: 'session' }), { type: 'session' });
  assert.equal(cookieReads, 0);
  await assert.rejects(engine.preview('https://example.com/video', { authentication: { type: 'session' } }), { code: 'processFailed' });
  assert.equal(cookieReads, 1);
  await assert.rejects(fs.stat(jar), { code: 'ENOENT' });
  await assert.rejects(new DownloadEngine({ tools }).preview('https://example.com/video', { authentication: { type: 'session' } }), { code: 'missingSiteSession' });
});
