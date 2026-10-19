import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { validateStyle, validateCues, parseSrt, toSrt, toAss } from '../src/subtitles/document.mjs';
import { createModelManager } from '../src/subtitles/models.mjs';
import { createSubtitleEngine, validateRequest, outputDirectoryFor } from '../src/subtitles/engine.mjs';

const cue = { start: 0.2, end: 1.7, text: 'Hello world', translation: '你好世界' };
test('style validation rejects invalid boundaries and canonicalizes color', () => {
  assert.deepEqual(validateStyle({ fontScale: 1.6, colorHex: 'ffe066', position: 'top' }), { fontScale: 1.6, colorHex: 'FFE066', position: 'top' });
  for (const fontScale of [0.59, 2.01, NaN, Infinity, '1']) assert.throws(() => validateStyle({ fontScale }));
  for (const colorHex of ['#FFFFFF', 'zzzzzz', 'FFFFFF\n']) assert.throws(() => validateStyle({ colorHex }));
  assert.throws(() => validateStyle({ position: 'left' }));
});

test('SRT parses whitespace/CRLF and preserves chunk offsets', () => {
  assert.deepEqual(parseSrt('1\r\n00:00:00,200 --> 00:00:01,700\r\nHello\r\nworld\r\n', 300), [{ start: 300.2, end: 301.7, text: 'Hello\nworld' }]);
  assert.equal(parseSrt('1\n00:99:00,000 --> 00:99:01,000\nBad').length, 0);
});

test('SRT renders translated and bilingual content at unchanged times', () => {
  assert.match(toSrt([cue]), /你好世界/);
  assert.doesNotMatch(toSrt([cue]), /Hello/);
  assert.match(toSrt([cue], true), /你好世界\nHello world/);
  assert.match(toSrt([cue]), /00:00:00,200 --> 00:00:01,700/);
});

test('ASS styles have no background box, use color/size/position, and escape override injection', () => {
  for (const [position, alignment] of [['top', 8], ['center', 5], ['bottom', 2]]) {
    const ass = toAss([{ ...cue, translation: '{\\bord99}你好\n世界' }], { width: 1920, height: 1080, style: { fontScale: 1.6, colorHex: 'FFE066', position } });
    assert.match(ass, /Noto Sans CJK SC,77\.8,&H0066E0FF/);
    assert.match(ass, /&HFF000000/);
    assert.match(ass, new RegExp(`,1,2\\.7,0,${alignment},`));
    assert.doesNotMatch(ass, /\{\\bord99\}/);
    assert.match(ass, /你好\\N世界/);
  }
});

test('cue validation rejects duration overrun and large or unordered results', () => {
  assert.throws(() => validateCues([]));
  assert.throws(() => validateCues([{ ...cue, start: 5, end: 6 }], 5));
  assert.throws(() => validateCues([{ ...cue, text: 'x'.repeat(4001) }]));
  assert.throws(() => validateCues([cue, { ...cue, start: 0.1 }]));
});

test('canonical output candidate is stable and retains the full task id', () => {
  const request = validateRequest({ id: '12345678-aaaa-bbbb-cccc-123456789012', inputPath: path.join(os.tmpdir(), 'test.mp4'), outputDirectory: os.tmpdir(), sourceLanguage: 'en', targetLanguage: 'zh', outputMode: 'burn', textMode: 'original' });
  assert.equal(outputDirectoryFor(request), outputDirectoryFor(request));
  assert.ok(outputDirectoryFor(request).endsWith('test_字幕_12345678-aaaa-bbbb-cccc-123456789012'));
  assert.equal(request.textMode, 'original');
  assert.equal(request.bilingual, false);
});

async function modelFixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'feather-model-test-'));
  t.after(() => fs.rm(directory, { force: true, recursive: true }));
  const bytes = Buffer.from('fixed public model fixture');
  const asset = { path: 'whisper/ggml-tiny.bin', url: 'https://huggingface.co/test/model/resolve/0123456789/file.bin', size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
  return { directory, bytes, asset };
}

test('models require explicit preparation and verify public download bytes', async t => {
  const { directory, bytes, asset } = await modelFixture(t);
  let calls = 0;
  const manager = createModelManager({ directory, assets: [asset], fetchImpl: async url => { calls++; assert.equal(url.hostname, 'huggingface.co'); return new Response(bytes); } });
  await assert.rejects(manager.requireReady(), /准备语言包/);
  assert.equal(calls, 0);
  assert.equal((await manager.prepare()).ready, true);
  await manager.requireReady();
  await manager.prepare();
  assert.equal(calls, 1);
  assert.equal((await manager.status()).bytesInstalled, bytes.length);
});

test('models reject hash mismatch and remove partials', async t => {
  const { directory, bytes, asset } = await modelFixture(t);
  const manager = createModelManager({ directory, assets: [asset], fetchImpl: async () => new Response(Buffer.alloc(bytes.length, 0)) });
  await assert.rejects(manager.prepare(), /校验失败/);
  assert.equal((await manager.status()).ready, false);
  assert.deepEqual(await fs.readdir(path.join(directory, 'whisper')), []);
});

test('model cancellation removes partial and can be retried', async t => {
  const { directory, bytes, asset } = await modelFixture(t);
  const controller = new AbortController();
  const manager = createModelManager({ directory, assets: [asset], fetchImpl: async () => {
    controller.abort(); return new Response(bytes);
  } });
  await assert.rejects(manager.prepare({ signal: controller.signal }));
  assert.deepEqual(await fs.readdir(path.join(directory, 'whisper')), []);
  assert.equal((await manager.status()).ready, false);
});

async function engineFixture(t, options = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'feather-subtitle-test-'));
  t.after(() => fs.rm(directory, { force: true, recursive: true }));
  const inputPath = path.join(directory, '原视频.mp4');
  await fs.writeFile(inputPath, 'original media bytes');
  const whisperPath = path.join(directory, 'whisper-model.bin');
  await fs.writeFile(whisperPath, 'synthetic model bytes');
  const calls = [];
  const modelRequests = [];
  const runProcess = async value => {
    calls.push(value);
    if (options.failure && calls.length === options.failure) throw new Error('injected stage failure');
    if (value.executable === 'probe') return { exitCode: 0, stdout: JSON.stringify({ format: { duration: String(options.duration || 5) }, streams: [{ codec_type: 'video', width: 3840, height: 2160 }, { codec_type: 'audio' }] }), peakMemoryBytes: 1000 };
    if (value.executable === 'whisper') await fs.writeFile(path.join(value.cwd, 'recognized.srt'), '1\n00:00:00,200 --> 00:00:01,700\nHello world\n');
    else if (value.executable === 'node') {
      const request = JSON.parse(await fs.readFile(value.args.at(-1), 'utf8'));
      await fs.writeFile(request.outputPath, JSON.stringify(request.texts.map(() => '你好世界')));
      value.onLine?.(JSON.stringify({ type: 'progress', completed: request.texts.length, total: request.texts.length }), 'stdout');
    } else if (value.executable === 'ffmpeg') await fs.writeFile(path.join(value.cwd, value.args.at(-1)), 'generated media');
    options.afterChild?.(value);
    return { exitCode: 0, stdout: '', peakMemoryBytes: 1000 };
  };
  const engine = createSubtitleEngine({ tools: { ffmpeg: 'ffmpeg', ffprobe: 'probe', whisper: 'whisper', node: 'node' }, modelDirectory: path.join(directory, 'models'), modelManager: { requireReady: async value => modelRequests.push(value), whisperPath }, runProcess, encoder: 'mpeg4' });
  return { directory, inputPath, calls, modelRequests, engine, request: { id: 'fixed-id', inputPath, outputDirectory: path.join(directory, 'out'), sourceLanguage: 'en', targetLanguage: 'zh', outputMode: 'srt', textMode: 'bilingual', style: { fontScale: 1.6, colorHex: 'FFE066', position: 'top' } } };
}

test('engine writes complete receipt before exposing result and leaves source unchanged', async t => {
  const f = await engineFixture(t);
  const result = await f.engine.run(f.request);
  assert.equal(await fs.readFile(f.inputPath, 'utf8'), 'original media bytes');
  const receipt = JSON.parse(await fs.readFile(result.receiptPath, 'utf8'));
  assert.equal(receipt.id, 'fixed-id');
  assert.equal(receipt.request.style.colorHex, 'FFE066');
  assert.equal(receipt.request.textMode, 'bilingual');
  assert.match(await fs.readFile(result.files[0], 'utf8'), /你好世界\nHello world/);
  assert.deepEqual((await fs.readdir(result.directory)).sort(), ['completion.json', '字幕.srt']);
  const asrArgs = f.calls.find(value => value.executable === 'whisper').args;
  assert.equal(asrArgs[asrArgs.indexOf('-m') + 1], 'whisper-model.bin');
  assert.equal(asrArgs[asrArgs.indexOf('-f') + 1], 'audio.wav');
  assert.equal(asrArgs[asrArgs.indexOf('-of') + 1], 'recognized');
  assert.ok(f.calls.every(x => x.limits.maximumMemoryBytes <= (x.executable === 'node' ? 3 : 2) * 1024 ** 3 && x.limits.totalTimeoutMs <= 30 * 60 * 1000));
});

test('original mode never loads translation model or starts translation worker', async t => {
  const f = await engineFixture(t);
  const result = await f.engine.run({ ...f.request, textMode: 'original' });
  assert.equal(f.modelRequests[0].translation, false);
  assert.ok(!f.calls.some(x => x.executable === 'node'));
  assert.match(await fs.readFile(result.files[0], 'utf8'), /Hello world/);
});

test('burn export caps frame size, uses safe relative ASS path, and forwards validated style', async t => {
  let ass = '';
  const f = await engineFixture(t, { afterChild: value => { if (value.executable === 'ffmpeg' && value.args.includes('-vf')) ass = value.args[value.args.indexOf('-vf') + 1]; } });
  const result = await f.engine.run({ ...f.request, outputMode: 'burn' });
  assert.equal(ass, 'scale=1920:1080,ass=captions.ass');
  assert.equal(result.files.length, 2);
  assert.equal(f.calls.at(-1).args.includes('-q:v'), true);
});

test('soft export copies existing video and uses independent switchable SRT stream', async t => {
  const f = await engineFixture(t);
  const result = await f.engine.run({ ...f.request, outputMode: 'soft' });
  assert.ok(result.files.some(x => x.endsWith('.mkv')));
  const args = f.calls.at(-1).args;
  assert.equal(args[args.indexOf('-c') + 1], 'copy');
  assert.equal(args[args.indexOf('-c:s') + 1], 'copy');
});

test('stage failure removes all staging media and permits another job', async t => {
  const f = await engineFixture(t, { failure: 3 });
  await assert.rejects(f.engine.run(f.request), /injected/);
  assert.deepEqual(await fs.readdir(f.request.outputDirectory), []);
  const result = await f.engine.run({ ...f.request, id: 'retry-id' });
  assert.ok(result.files.length);
});

test('cancellation after child completion cannot publish partial result', async t => {
  const controller = new AbortController();
  const f = await engineFixture(t, { afterChild: value => { if (value.executable === 'whisper') controller.abort(); } });
  await assert.rejects(f.engine.run(f.request, { signal: controller.signal }));
  assert.deepEqual(await fs.readdir(f.request.outputDirectory), []);
});

test('overlong video fails before audio extraction', async t => {
  const f = await engineFixture(t, { duration: 7201 });
  await assert.rejects(f.engine.run(f.request), /最长 2 小时/);
  assert.equal(f.calls.length, 1);
  assert.deepEqual(await fs.readdir(f.request.outputDirectory), []);
});
