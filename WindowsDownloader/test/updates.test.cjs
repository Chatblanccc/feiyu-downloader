'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { UpdateService, RELEASES, applicationBusy } = require('../src/update-service.cjs');
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const metadata = () => ({ version: '0.4.1', releaseNotes: '<p>保留设置，改善更新体验。</p>', files: [{ url: 'FeiyuDownload-0.4.1-Windows-x64-Setup.exe', size: 1024, sha512: Buffer.alloc(64, 7).toString('base64') }] });
function fixture(options = {}) {
  const updater = new EventEmitter();
  updater.calls = { check: 0, download: 0, install: 0 };
  updater.setFeedURL = value => { updater.feed = value; };
  updater.checkForUpdates = async () => {
    updater.calls.check++; const cancellationToken = { cancelled: false, cancel() { this.cancelled = true; } };
    return { isUpdateAvailable: true, updateInfo: metadata(), cancellationToken };
  };
  updater.downloadUpdate = async () => { updater.calls.download++; return ['C:\\cache\\update.exe']; };
  updater.quitAndInstall = (...args) => { updater.calls.install++; updater.installArgs = args; };
  return { updater, service: new UpdateService({ updater, version: '0.4.0', ...options }) };
}
test('checking is manual and public, stable releases and full NSIS packages only, with no quit installation', async () => {
  const { updater, service } = fixture();
  assert.deepEqual(updater.feed, RELEASES);
  assert.equal(updater.calls.check, 0);
  assert.equal(updater.autoDownload, false); assert.equal(updater.autoInstallOnAppQuit, false);
  assert.equal(updater.allowPrerelease, false); assert.equal(updater.allowDowngrade, false);
  assert.equal(updater.disableWebInstaller, true); assert.equal(updater.disableDifferentialDownload, true);
  assert.equal((await service.check()).status, 'available');
  assert.equal(service.snapshot().version, '0.4.1'); assert.equal(service.snapshot().size, 1024);
  assert.match(service.snapshot().notes, /保留设置/); assert.doesNotMatch(service.snapshot().notes, /<p>/);
  assert.equal(updater.calls.download, 0); assert.equal(updater.calls.install, 0);
});
test('up-to-date results and friendly offline/no-release errors do not download', async () => {
  const { updater, service } = fixture();
  updater.checkForUpdates = async () => ({ isUpdateAvailable: false, updateInfo: { version: '0.4.0' } });
  assert.equal((await service.check()).status, 'up-to-date');
  updater.checkForUpdates = async () => { throw Object.assign(new Error('private network details'), { code: 'ERR_UPDATER_LATEST_VERSION_NOT_FOUND' }); };
  assert.match((await service.check()).error, /暂时没有可用/);
  updater.checkForUpdates = async () => { throw new Error('https://private.example/token-secret'); };
  const failed = await service.check(); assert.match(failed.error, /网络/); assert.doesNotMatch(failed.error, /token-secret|private.example/);
  assert.equal(updater.calls.download, 0);
});
test('development and unsupported platform cannot check or install', () => {
  const { updater, service } = fixture({ supported: false });
  assert.equal(service.snapshot().status, 'unavailable');
  assert.throws(() => service.check(), /安装后的 Windows/);
  assert.throws(() => service.download(), /安装后的 Windows/);
  assert.equal(updater.calls.check, 0); assert.equal(updater.calls.install, 0);
});
test('incomplete checksums, unknown asset paths, sizes and web installers cannot be offered', async () => {
  for (const mutate of [info => { delete info.files[0].sha512; }, info => { info.files[0].url = 'https://untrusted.example/update.exe'; }, info => { info.files[0].size = 0; }, info => { info.packages = {}; }]) {
    const { updater, service } = fixture();
    const info = metadata(); mutate(info);
    updater.checkForUpdates = async () => ({ isUpdateAvailable: true, updateInfo: info, cancellationToken: { cancel() {} } });
    assert.equal((await service.check()).status, 'error'); assert.equal(updater.calls.download, 0);
  }
});
test('duplicate checks and download requests share one operation; progress stays bounded', async () => {
  const { updater, service } = fixture(); const checking = deferred(), downloading = deferred();
  updater.checkForUpdates = () => { updater.calls.check++; return checking.promise; };
  const first = service.check(), second = service.check(); assert.equal(first, second);
  checking.resolve({ isUpdateAvailable: true, updateInfo: metadata(), cancellationToken: { cancel() {} } }); await first;
  assert.equal(updater.calls.check, 1);
  updater.downloadUpdate = () => { updater.calls.download++; return downloading.promise; };
  const a = service.download(), b = service.download(); assert.equal(a, b);
  await Promise.resolve(); assert.equal(updater.calls.download, 1);
  updater.emit('download-progress', { transferred: 2048, total: 1024, bytesPerSecond: 40 }); assert.equal(service.snapshot().progress.percent, 100);
  downloading.resolve(['C:\\update.exe']); assert.equal((await a).status, 'downloaded'); assert.equal(updater.calls.install, 0);
});
test('cancelling even a just-completed download never makes it installable and recheck supplies a new token', async () => {
  const { updater, service } = fixture(); await service.check(); const token = service.token, downloading = deferred();
  updater.downloadUpdate = () => downloading.promise;
  const work = service.download(); await Promise.resolve(); assert.equal(service.cancel().status, 'cancelling'); assert.equal(token.cancelled, true);
  updater.emit('download-progress', { transferred: 900, total: 1024 });
  downloading.resolve(['C:\\update.exe']); assert.equal((await work).status, 'cancelled');
  assert.throws(() => service.install(), /下载并校验/);
  await service.check(); assert.notEqual(service.token, token); assert.equal(service.token.cancelled, false);
});
test('corrupted or signature-rejected downloads cannot install even after a premature downloaded event', async () => {
  const { updater, service } = fixture(); await service.check();
  updater.downloadUpdate = async () => { updater.emit('update-downloaded', metadata()); throw Object.assign(new Error('sha512 checksum mismatch'), { code: 'ERR_CHECKSUM_MISMATCH' }); };
  const result = await service.download(); assert.equal(result.status, 'error'); assert.match(result.error, /完整性或签名/);
  assert.throws(() => service.install(), /下载并校验/); assert.equal(updater.calls.install, 0);
});
test('queued/active downloads, preview, subtitles, models and open website sessions each block restart', async () => {
  const controller = { downloads: { snapshot: () => ({ activeCount: 0, tasks: [] }) } };
  assert.equal(applicationBusy(controller, null), false);
  for (const snapshot of [{ activeCount: 1 }, { previewing: true }, { tasks: [{ status: 'queued' }] }, { tasks: [{ status: 'processing' }] }]) assert.equal(applicationBusy({ downloads: { snapshot: () => snapshot } }, null), true);
  assert.equal(applicationBusy({ ...controller, activeSubtitle: {} }, null), true);
  assert.equal(applicationBusy({ ...controller, activePreparation: {} }, null), true);
  assert.equal(applicationBusy(controller, { isBusy: () => true }), true);
  let busy = true; const { updater, service } = fixture({ isBusy: () => busy }); await service.check(); await service.download();
  assert.equal((await service.install()).status, 'downloaded'); assert.match(service.snapshot().error, /关闭应用内网站会话/); assert.equal(updater.calls.install, 0);
  busy = false; await service.install(); assert.equal(updater.calls.install, 1);
});
test('in-flight IPC work reserves admission before async preparation starts', async () => {
  const { updater, service } = fixture(); await service.check(); await service.download(); const job = deferred();
  const activity = service.runActivity(() => job.promise);
  assert.equal((await service.install()).status, 'downloaded'); assert.equal(updater.calls.install, 0);
  job.resolve(); await activity; await service.install(); assert.equal(updater.calls.install, 1);
});
test('restart locks new jobs, waits for orderly state flush, then invokes one silent restart installation', async () => {
  const cleanup = deferred(), order = [];
  const { updater, service } = fixture({ prepareInstall: async () => { order.push('flush-start'); await cleanup.promise; order.push('flush-done'); } });
  updater.quitAndInstall = (...args) => { order.push('install'); updater.calls.install++; updater.installArgs = args; };
  await service.check(); await service.download(); const installation = service.install();
  await Promise.resolve(); assert.deepEqual(order, ['flush-start']);
  await assert.rejects(service.runActivity(() => assert.fail('new job started')), /重启更新/);
  assert.throws(() => service.install(), /正在保存并安装/); assert.equal(updater.calls.install, 0);
  cleanup.resolve(); await installation;
  assert.deepEqual(order, ['flush-start', 'flush-done', 'install']); assert.equal(updater.calls.install, 1); assert.deepEqual(updater.installArgs, [true, true]);
});
test('failed persistence and installer launch are reported and never reopen admission on a closed controller', async () => {
  const { updater, service } = fixture({ prepareInstall: async () => { throw new Error('save failed'); } });
  await service.check(); await service.download(); assert.equal((await service.install()).status, 'error'); assert.equal(updater.calls.install, 0);
  await assert.rejects(service.runActivity(() => {}), /重启更新/);
  const other = fixture(); await other.service.check(); await other.service.download();
  other.updater.quitAndInstall = () => other.updater.emit('error', new Error('installer spawn failed'));
  assert.equal((await other.service.install()).status, 'error'); assert.match(other.service.snapshot().error, /安装未能启动/);
});
