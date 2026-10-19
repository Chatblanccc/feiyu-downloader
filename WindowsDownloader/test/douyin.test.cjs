'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { readDouyinPage, douyinInfo } = require('../src/douyin.cjs');
const { DownloadEngine, DownloadManager, FINAL_PREFIX } = require('../src/core');
const { createSiteSession } = require('../src/site-session.cjs');

function player() {
  return { awemeId: '1234567890123456789', desc: '当前视频', authenticationToken: 'account-secret', video: {
    width: 1920, height: 1080, duration: 12000, playAddr: [{ src: 'https://v3-web.douyinvod.com/video?token=temporary' }],
    bitRateList: [
      { format: 'mp4', width: 1920, height: 1080, fps: 30, bitRate: 1000000, dataSize: 100, isH265: 0, playAddr: [{ src: 'https://v3-web.douyinvod.com/1080?token=temporary' }] },
      { format: 'dash', width: 1920, height: 1080, playAddr: [{ src: 'https://v3-web.douyinvod.com/video-only' }] },
      { format: 'mp4', width: 1280, height: 720, isH265: 1, playAddr: [{ src: 'https://v3-web.douyinvod.com/720?token=temporary' }] }
    ]
  } };
}
function readPlayer(data = player(), host = 'www.douyin.com') {
  return vm.runInNewContext(`
    const current=${JSON.stringify(data)};
    const other={awemeId:'999999',desc:'推荐视频',video:current.video};
    const video={__reactFiber$test:{memoizedProps:{nextVideoInfo:other,awemeInfo:current}}};
    const document={title:'视频网站',querySelectorAll:()=>[video]};
    const location={pathname:'/video/1234567890123456789',hostname:${JSON.stringify(host)}};
    (${readDouyinPage.toString()})()
  `);
}

test('Douyin page reader selects the current video and exports only combined media formats', () => {
  const text = readPlayer();
  const raw = JSON.parse(text), info = douyinInfo(text, 'Browser UA');
  assert.equal(raw.id, '1234567890123456789');
  assert.equal(raw.title, '当前视频');
  assert.equal(info.duration, 12);
  assert.equal(info.formats.length, 2);
  assert.deepEqual(info.formats.map(format => format.height), [1080, 720]);
  assert.ok(info.formats.every(format => format.acodec === 'aac'));
  assert.equal(info.http_headers.Referer, 'https://www.douyin.com/');
  assert.doesNotMatch(text, /account-secret|authenticationToken|推荐视频|video-only/);
  assert.equal(readPlayer(player(), 'douyin.com.attacker.example'), null);
  assert.equal(readPlayer({ ...player(), awemeId: '999999' }), null);
  assert.equal(readPlayer({ ...player(), status: { isProhibited: true } }), null);
});

test('Douyin metadata rejects non-media hosts and malformed records', () => {
  const raw = JSON.parse(readPlayer());
  raw.video.bitRateList = [];
  raw.video.playAddr = [{ src: 'https://douyinvod.com.attacker.example/video' }, { src: 'file:///C:/private' }];
  assert.throws(() => douyinInfo(JSON.stringify(raw), 'UA'), { code: 'invalidMetadata' });
  assert.throws(() => douyinInfo('{}', 'UA'), { code: 'invalidMetadata' });
});

test('session-backed download uses disposable info JSON and never persists signed media URLs in history', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'FeiyuDouyin-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const raw = douyinInfo(readPlayer(), 'UA'), directory = path.join(root, 'videos'), dataDirectory = path.join(root, 'data');
  let infoPath, requests = 0;
  const engine = new DownloadEngine({ tools: { ytDlp: process.execPath, ffmpeg: process.execPath },
    sessionMetadata: async () => raw,
    sessionAuthentication: async () => ({ args: ['--no-cookies', '--no-cookies-from-browser'], cleanup: async () => {} }),
    runner: async options => {
      requests++;
      assert.equal(options.args.includes('--dump-single-json'), false);
      infoPath = options.args[options.args.indexOf('--load-info-json') + 1];
      const info = JSON.parse(await fs.readFile(infoPath, 'utf8'));
      assert.equal(info.title, '当前视频');
      assert.match(info.formats[0].url, /token=temporary/);
      const file = path.join(directory, '当前视频.mp4'); await fs.writeFile(file, 'media');
      options.onLine(FINAL_PREFIX + JSON.stringify(file), 'stdout');
      return { exitCode: 0, stderr: '' };
    }
  });
  const manager = new DownloadManager({ engine, dataDirectory, downloadDirectory: directory });
  await manager.init();
  const done = new Promise(resolve => manager.on('change', state => { if (state.tasks[0]?.status === 'completed') resolve(); }));
  await manager.add('https://www.douyin.com/video/' + raw.id, { authentication: { type: 'session' } });
  await done; await manager.close();
  assert.equal(requests, 1);
  await assert.rejects(fs.stat(infoPath), { code: 'ENOENT' });
  const history = await fs.readFile(path.join(dataDirectory, 'download-history.json'), 'utf8');
  assert.match(history, /当前视频/);
  assert.doesNotMatch(history, /douyinvod|token=|downloadInfo|formats/);
});

test('cancelling a website extraction closes its hidden window promptly', async () => {
  let destroyed = false;
  const fakeSession = { setPermissionRequestHandler() {}, setPermissionCheckHandler() {}, on() {}, getUserAgent: () => 'Browser UA', setUserAgent() {} };
  class FakeWindow {
    webContents = { setAudioMuted() {}, setWindowOpenHandler() {}, on() {} };
    isDestroyed() { return destroyed; }
    destroy() { destroyed = true; }
    loadURL() { return new Promise(() => {}); }
  }
  const service = createSiteSession({ BrowserWindow: FakeWindow, session: { fromPartition: () => fakeSession }, parent: () => undefined });
  const controller = new AbortController();
  const pending = service.metadata('https://www.douyin.com/video/1234567890123456789', { signal: controller.signal });
  controller.abort();
  await assert.rejects(pending, { code: 'cancelled' });
  assert.equal(destroyed, true);
});
