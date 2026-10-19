'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { DownloadEngine, DownloadError, FINAL_PREFIX, readableFailure } = require('../src/core');
const { createSiteSession } = require('../src/site-session.cjs');
const { douyinInfo, supportsDouyinURL } = require('../src/douyin.cjs');

const tools = { ytDlp: process.execPath, ffmpeg: process.execPath };
const videoURL = 'https://www.douyin.com/video/1234567890123456789';
const siteFailure = { exitCode: 1, stdout: '', stderr: 'ERROR: [Douyin] Fresh cookies (not necessarily logged in) are needed' };
const cookieFailure = { exitCode: 1, stdout: '', stderr: 'ERROR: Failed to decrypt with DPAPI' };
function pageRecord() {
  return JSON.stringify({ id: '1234567890123456789', title: '公开测试视频', video: {
    width: 1920, height: 1080, duration: 12000,
    playAddr: [{ src: 'https://v3-web.douyinvod.com/video?token=temporary' }],
    bitRateList: [{ width: 1920, height: 1080, fps: 30, bitRate: 1000000, dataSize: 42, isH265: 0, playAddr: [{ src: 'https://v3-web.douyinvod.com/video?token=temporary' }] }]
  } });
}
const rawInfo = () => douyinInfo(pageRecord(), 'Test Browser UA');
function credentialProvidersMustNotRun() {
  return {
    sessionMetadata: async () => assert.fail('Anonymous extraction must not read the saved website session'),
    sessionAuthentication: async () => assert.fail('Anonymous extraction must not export saved website cookies')
  };
}

test('Windows public Douyin extraction falls back only after yt-dlp fails and never reads saved credentials', async () => {
  const calls = [], controller = new AbortController();
  const engine = new DownloadEngine({ tools, platform: 'win32', ...credentialProvidersMustNotRun(),
    runner: async options => { calls.push('yt-dlp'); assert.ok(options.args.includes('--no-cookies')); assert.ok(options.args.includes('--no-cookies-from-browser')); return siteFailure; },
    anonymousMetadata: async (url, { signal }) => { calls.push('anonymous'); assert.equal(url, videoURL); assert.equal(signal, controller.signal); return rawInfo(); }
  });
  const info = await engine.preview(videoURL, { signal: controller.signal });
  assert.deepEqual(calls, ['yt-dlp', 'anonymous']);
  assert.equal(info.id, rawInfo().id);
  assert.equal(info.title, '公开测试视频');
  assert.deepEqual(info.availableHeights, [1080]);
  assert.equal(info.formats[0].hasVideo, true);
  assert.equal(info.formats[0].hasAudio, true);
  assert.deepEqual(info.downloadInfo, rawInfo());
});

test('successful public extraction does not open an anonymous website', async () => {
  const engine = new DownloadEngine({ tools, platform: 'win32', ...credentialProvidersMustNotRun(),
    runner: async () => ({ exitCode: 0, stdout: JSON.stringify(rawInfo()), stderr: '' }),
    anonymousMetadata: async () => assert.fail('yt-dlp succeeded')
  });
  const info = await engine.preview(videoURL);
  assert.equal(info.title, '公开测试视频');
  assert.equal(info.downloadInfo, undefined);
});

test('broken Windows browser cookies can reach anonymous extraction and are not read again for download', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'FeiyuAnonymousBrowser-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const calls = [];
  const engine = new DownloadEngine({ tools, platform: 'win32', ...credentialProvidersMustNotRun(),
    anonymousMetadata: async () => rawInfo(),
    runner: async options => {
      calls.push(options.args);
      if (options.args.includes('--cookies-from-browser')) return cookieFailure;
      assert.ok(options.args.includes('--no-cookies'));
      assert.ok(options.args.includes('--no-cookies-from-browser'));
      if (options.args.includes('--dump-single-json')) return siteFailure;
      assert.ok(options.args.includes('--load-info-json'));
      const file = path.join(directory, 'public.mp4');
      await fs.writeFile(file, 'video');
      options.onLine(FINAL_PREFIX + JSON.stringify(file), 'stdout');
      return { exitCode: 0, stderr: '' };
    }
  });
  const authentication = { type: 'browser', browser: 'chrome' };
  const info = await engine.preview(videoURL, { authentication });
  assert.equal(info.anonymousFallback, true);
  await engine.download(info, { directory, authentication });
  assert.equal(calls.length, 3);
  assert.equal(calls.filter(args => args.includes('--cookies-from-browser')).length, 1);
});

test('unsupported URLs and non-Windows platforms preserve the original failure without opening an anonymous page', async () => {
  const cases = [
    ['darwin', videoURL], ['linux', videoURL],
    ['win32', 'https://example.com/video/123'],
    ['win32', 'https://live.douyin.com/123456'],
    ['win32', 'https://www.douyin.com/user/123456'],
    ['win32', 'https://douyin.com.attacker.example/video/123456']
  ];
  for (const [platform, url] of cases) {
    const engine = new DownloadEngine({ tools, platform,
      runner: async () => siteFailure,
      anonymousMetadata: async () => assert.fail('Unexpected anonymous fallback: ' + platform + ' ' + url)
    });
    await assert.rejects(engine.preview(url), error => error.code === 'processFailed' && error.message === readableFailure(siteFailure.stderr));
  }
});

test('explicit browser authentication errors unrelated to cookie loading do not change credentials', async () => {
  const engine = new DownloadEngine({ tools, platform: 'win32', runner: async () => siteFailure,
    anonymousMetadata: async () => assert.fail('The selected browser did not have a cookie-loading failure')
  });
  await assert.rejects(engine.preview(videoURL, { authentication: { type: 'browser', browser: 'chrome' } }), { code: 'processFailed' });
});

test('cancellation, launch failures and resource limits never start an anonymous fallback', async () => {
  for (const code of ['cancelled', 'launchFailed', 'timedOut', 'outputTooLarge', 'memoryLimitExceeded']) {
    const failure = new DownloadError(code);
    const engine = new DownloadEngine({ tools, platform: 'win32', runner: async () => { throw failure; },
      anonymousMetadata: async () => assert.fail('Unexpected fallback for ' + code)
    });
    await assert.rejects(engine.preview(videoURL), error => error === failure);
  }
  const controller = new AbortController();
  const engine = new DownloadEngine({ tools, platform: 'win32',
    runner: async () => { controller.abort(); return siteFailure; },
    anonymousMetadata: async () => assert.fail('A cancelled extraction must not open a new page')
  });
  await assert.rejects(engine.preview(videoURL, { signal: controller.signal }), { code: 'cancelled' });
});

test('an anonymous provider with no result preserves the original site error', async () => {
  let calls = 0;
  const engine = new DownloadEngine({ tools, platform: 'win32', runner: async () => siteFailure,
    anonymousMetadata: async () => { calls++; return null; }
  });
  await assert.rejects(engine.preview(videoURL), error => error.code === 'processFailed' && error.message === readableFailure(siteFailure.stderr));
  assert.equal(calls, 1);
});

test('anonymous provider output must be valid video metadata', async () => {
  const engine = new DownloadEngine({ tools, platform: 'win32', runner: async () => siteFailure,
    anonymousMetadata: async () => ({ id: '1234567890123456789', title: '', formats: [] })
  });
  await assert.rejects(engine.preview(videoURL), { code: 'invalidMetadata' });
});

test('anonymous download uses temporary info JSON without cookie access and removes it after success or failure', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'FeiyuAnonymousDownload-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  for (const succeeds of [true, false]) {
    let filename;
    const engine = new DownloadEngine({ tools, platform: 'win32', ...credentialProvidersMustNotRun(),
      anonymousMetadata: async () => rawInfo(),
      runner: async options => {
        if (options.args.includes('--dump-single-json')) return siteFailure;
        assert.ok(options.args.includes('--no-cookies'));
        assert.ok(options.args.includes('--no-cookies-from-browser'));
        assert.equal(options.args.includes('--cookies'), false);
        assert.equal(options.args.includes('--cookies-from-browser'), false);
        filename = options.args[options.args.indexOf('--load-info-json') + 1];
        assert.deepEqual(JSON.parse(await fs.readFile(filename, 'utf8')), rawInfo());
        if (!succeeds) return siteFailure;
        const file = path.join(directory, 'public.mp4');
        await fs.writeFile(file, 'video');
        options.onLine(FINAL_PREFIX + JSON.stringify(file), 'stdout');
        return { exitCode: 0, stderr: '' };
      }
    });
    const info = await engine.preview(videoURL);
    if (succeeds) assert.equal((await engine.download(info, { directory })).fileSize, 5);
    else await assert.rejects(engine.download(info, { directory }), { code: 'processFailed' });
    assert.ok(filename);
    await assert.rejects(fs.stat(filename), { code: 'ENOENT' });
    await assert.rejects(fs.stat(path.dirname(filename)), { code: 'ENOENT' });
  }
});

test('anonymous Douyin URL support accepts video links and rejects live, profile, credential and lookalike hosts', () => {
  for (const url of [videoURL, 'https://v.douyin.com/Example/', 'https://www.douyin.com/?modal_id=123456', 'https://www.iesdouyin.com/share/video/123456/']) {
    assert.equal(supportsDouyinURL(url), true, url);
  }
  for (const url of ['https://live.douyin.com/123456', 'https://www.douyin.com/user/123456', 'https://www.douyin.com/', 'https://www.douyin.com/video/not-a-number', 'https://douyin.com.attacker.example/video/123456', 'https://example.com/?modal_id=123456', 'https://private@www.douyin.com/video/123456', 'file:///video/123456']) {
    assert.equal(supportsDouyinURL(url), false, url);
  }
});

function fakeWebsite({ loadFailure = false, pendingLoad = false, invalidPage = false, landingURL, onRead } = {}) {
  const partitions = [], sessions = [], windows = [];
  const session = { fromPartition(name) {
    partitions.push(name);
    const value = {
      partition: name, storageClears: 0, cacheClears: 0, cookieReads: 0,
      setPermissionRequestHandler() {}, setPermissionCheckHandler() {}, on() {}, setUserAgent() {},
      getUserAgent: () => 'Mozilla/5.0 Chrome/152.0.0.0 feiyu-downloader/0.3.1 Electron/44.9.0',
      cookies: { get: async () => { value.cookieReads++; assert.fail('Anonymous extraction must not read cookies'); } },
      clearStorageData: async () => { value.storageClears++; },
      clearCache: async () => { value.cacheClears++; }
    };
    sessions.push(value);
    return value;
  } };
  class FakeWindow {
    constructor(options) {
      this.options = options; this.destroyed = false; this.listeners = new Map(); windows.push(this);
      this.webContents = {
        setAudioMuted() {}, setWindowOpenHandler() {},
        on: (name, listener) => {
          if (!this.listeners.has(name)) this.listeners.set(name, []);
          this.listeners.get(name).push(listener);
        },
        getURL: () => landingURL || this.loadedURL,
        executeJavaScript: async () => { onRead?.(this); return invalidPage ? '{"id":"wrong"}' : pageRecord(); }
      };
    }
    isDestroyed() { return this.destroyed; }
    destroy() { this.destroyed = true; }
    async loadURL(value) { this.loadedURL = value; if (loadFailure) throw new Error('Network failed'); if (pendingLoad) return new Promise(() => {}); }
    navigationPrevented(name, value) {
      let prevented = false;
      for (const listener of this.listeners.get(name) || []) listener({ preventDefault() { prevented = true; } }, value);
      return prevented;
    }
  }
  const service = createSiteSession({ BrowserWindow: FakeWindow, session, parent: () => null });
  return { service, partitions, sessions, windows };
}
function assertAnonymousCleanup(fake, expectedWindows) {
  assert.equal(fake.windows.length, expectedWindows);
  const anonymous = fake.sessions.filter(session => !session.partition.startsWith('persist:'));
  assert.equal(anonymous.length, expectedWindows);
  assert.equal(new Set(anonymous.map(session => session.partition)).size, expectedWindows);
  assert.ok(anonymous.every(session => session.storageClears >= 1 && session.cacheClears >= 1));
  assert.ok(fake.sessions.every(session => session.cookieReads === 0));
  for (const window of fake.windows) {
    assert.equal(window.destroyed, true);
    assert.equal(window.options.show, false);
    assert.equal(window.options.webPreferences.session.partition.startsWith('persist:'), false);
    assert.equal(window.options.webPreferences.nodeIntegration, false);
    assert.equal(window.options.webPreferences.sandbox, true);
  }
}

test('anonymous extraction creates a fresh in-memory session per request and clears its website data', async () => {
  const fake = fakeWebsite();
  for (let n = 0; n < 2; n++) {
    const info = await fake.service.anonymousMetadata(videoURL);
    assert.equal(info.id, rawInfo().id);
    assert.equal(info.formats[0].acodec, 'aac');
    assert.doesNotMatch(info.http_headers['User-Agent'], /Electron|feiyu-downloader/);
  }
  assertAnonymousCleanup(fake, 2);
  fake.service.close();
});

test('anonymous extraction clears its in-memory session after website or metadata failures', async () => {
  for (const options of [{ loadFailure: true }, { invalidPage: true }]) {
    const fake = fakeWebsite(options);
    await assert.rejects(fake.service.anonymousMetadata(videoURL));
    assertAnonymousCleanup(fake, 1);
    fake.service.close();
  }
});

test('cancelling anonymous page loading destroys the window and clears in-memory data', async () => {
  const fake = fakeWebsite({ pendingLoad: true }), controller = new AbortController();
  const pending = fake.service.anonymousMetadata(videoURL, { signal: controller.signal });
  controller.abort();
  await assert.rejects(pending, { code: 'cancelled' });
  assertAnonymousCleanup(fake, 1);
  fake.service.close();
});

test('anonymous service ignores unsupported URLs without opening any website', async () => {
  const fake = fakeWebsite();
  for (const url of ['https://live.douyin.com/123456', 'https://www.douyin.com/user/123456', 'https://example.com/video/123456']) {
    assert.equal(await fake.service.anonymousMetadata(url), null);
  }
  assertAnonymousCleanup(fake, 0);
  fake.service.close();
});

test('anonymous short links bind extraction to the numeric video identity after redirect', async () => {
  const shortURL = 'https://v.douyin.com/Example/', fake = fakeWebsite({ landingURL: videoURL });
  const info = await fake.service.anonymousMetadata(shortURL);
  assert.equal(fake.windows[0].loadedURL, shortURL);
  assert.equal(info.id, rawInfo().id);
  assert.equal(info.webpage_url, videoURL);
  assertAnonymousCleanup(fake, 1);
  fake.service.close();
});

test('anonymous short links reject video metadata that differs from their landing page and still clean up', async () => {
  const fake = fakeWebsite({ landingURL: 'https://www.douyin.com/video/9999999999999999999' });
  await assert.rejects(fake.service.anonymousMetadata('https://v.douyin.com/Example/'), { code: 'invalidMetadata' });
  assertAnonymousCleanup(fake, 1);
  fake.service.close();
});

test('anonymous short links without a numeric landing video cannot select a recommendation', async () => {
  for (const landingURL of ['https://www.douyin.com/', 'https://www.douyin.com/user/123456', 'https://example.com/video/1234567890123456789']) {
    const fake = fakeWebsite({ landingURL });
    await assert.rejects(fake.service.anonymousMetadata('https://v.douyin.com/Example/'), { code: 'invalidMetadata' });
    assertAnonymousCleanup(fake, 1);
    fake.service.close();
  }
});

test('anonymous pages deny foreign navigation and different videos after the short-link identity is fixed', async () => {
  let checked = false;
  const fake = fakeWebsite({ landingURL: videoURL, onRead(window) {
    checked = true;
    for (const event of ['will-navigate', 'will-redirect']) {
      assert.equal(window.navigationPrevented(event, 'https://example.com/video/1234567890123456789'), true);
      assert.equal(window.navigationPrevented(event, 'https://www.douyin.com/video/9999999999999999999'), true);
      assert.equal(window.navigationPrevented(event, videoURL), false);
      assert.equal(window.navigationPrevented(event, 'https://www.douyin.com/?modal_id=1234567890123456789'), false);
    }
  } });
  await fake.service.anonymousMetadata('https://v.douyin.com/Example/');
  assert.equal(checked, true);
  assertAnonymousCleanup(fake, 1);
  fake.service.close();
});
