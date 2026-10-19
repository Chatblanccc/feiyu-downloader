import fs from 'node:fs/promises';
import path from 'node:path';
import { LANGUAGES } from './document.mjs';

async function main() {
  const [requestPath] = process.argv.slice(2);
  if (!requestPath) throw new Error('缺少翻译请求。');
  const stat = await fs.stat(requestPath);
  if (stat.size > 1200000) throw new Error('翻译请求过大。');
  const request = JSON.parse(await fs.readFile(requestPath, 'utf8'));
  const allowed = new Set(LANGUAGES.map(x => x.code));
  if (!allowed.has(request.sourceLanguage) || !allowed.has(request.targetLanguage) || !Array.isArray(request.texts) || request.texts.length > 20000 || request.texts.some(x => typeof x !== 'string' || x.length > 4000)) throw new Error('翻译语言或文本格式不正确。');
  // The pinned Transformers version creates its encoder and decoder in parallel.
  // Serialize native session construction inside this isolated worker to avoid
  // having both ONNX parsers/initializers allocate temporary model copies at once.
  const runtime = await import('onnxruntime-node');
  const nativeCreate = runtime.InferenceSession.create;
  let sessionQueue = Promise.resolve();
  runtime.InferenceSession.create = function (...args) {
    const pending = sessionQueue.then(() => nativeCreate.apply(this, args));
    sessionQueue = pending.catch(() => {});
    return pending;
  };
  const { env, pipeline } = await import('@huggingface/transformers');
  env.allowRemoteModels = false;
  env.allowLocalModels = true;
  env.localModelPath = path.resolve(request.modelDirectory) + path.sep;
  env.useBrowserCache = false;
  // In Node this also lets ONNX load its file path directly. Disabling it copies
  // both large model files into JS buffers and causes a multi-gigabyte startup spike.
  env.useFSCache = true;
  env.cacheDir = path.join(path.resolve(request.modelDirectory), '.transformers-cache');
  const translate = await pipeline('translation', 'm2m100', {
    dtype: 'q8', device: 'cpu', local_files_only: true,
    session_options: { intraOpNumThreads: 4, interOpNumThreads: 1, executionMode: 'sequential', graphOptimizationLevel: 'all', enableCpuMemArena: false, enableMemPattern: false, extra: { session: { disable_prepacking: '1' } } },
  });
  const output = [];
  process.stdout.write(JSON.stringify({ type: 'resource', phase: 'modelsReady', rss: process.memoryUsage().rss }) + '\n');
  try {
    for (let index = 0; index < request.texts.length; index++) {
      // Keep one cue in flight; short subtitle segments bound attention/cache size.
      const pieces = request.texts[index].match(/[\s\S]{1,450}(?:[。！？.!?\s]|$)|[\s\S]{1,450}/g) || [''];
      const translated = [];
      for (const piece of pieces) {
        const result = await translate(piece, { src_lang: request.sourceLanguage, tgt_lang: request.targetLanguage, max_new_tokens: 192, num_beams: 1, repetition_penalty: 1.1 });
        const text = result?.[0]?.translation_text;
        if (typeof text !== 'string' || !text.trim()) throw new Error('翻译模型没有返回字幕文本。');
        translated.push(text.trim());
      }
      output.push(translated.join(' '));
      process.stdout.write(JSON.stringify({ type: 'progress', completed: index + 1, total: request.texts.length }) + '\n');
    }
    await fs.writeFile(request.outputPath, JSON.stringify(output), { flag: 'wx', mode: 0o600 });
  } finally { await translate.dispose(); }
}

main().catch(error => { process.stderr.write(String(error?.message || error).slice(0, 4000) + '\n'); process.exitCode = 1; });
