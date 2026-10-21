#!/usr/bin/env python3
"""Offline SeedVR2 adapter. stdout is the Feather NDJSON protocol.

The host owns the process group. This worker never creates another session,
downloads a model, or stores the whole video or a PNG sequence in memory/on disk.
"""
from __future__ import annotations

import argparse
import contextlib
import ctypes
import errno
import gc
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback

GIB = 1024 ** 3
REVISION = '4490bd1f482e026674543386bb2a4d176da245b9'
CLI_SHA256 = '7e3234ae1079227e39ec98fcc8ed09c12ac9974997b82bf02404ba38ffff0aba'
MODELS = {
    'seedvr2_ema_3b_fp16.safetensors': (6783018808, '2fd0e03a3dad24e07086750360727ca437de4ecd456f769856e960ae93e2b304'),
    'ema_vae_fp16.safetensors': (501324814, '20678548f420d98d26f11442d3528f8b8c94e57ee046ef93dbb7633da8612ca1'),
}
LIMITATIONS = [
    'SeedVR2 会根据画面推测纹理，可能改动人脸、文字、商标或小图案，不能用于确认真实身份或恢复证据。',
    '运动、遮挡、镜头切换及分块交界可能出现闪烁、重影或纹理变化；时间重叠混合只能减轻接缝，不能保证消除失真。',
    '离线运行需要另行下载模型与运行组件；速度取决于本机 GPU 和画面尺寸，长视频可能耗时很久。',
    '当前组件只支持 Apple Silicon 的 MPS，不支持马赛克去除、HDR 或 CPU 自动回退；音频会转码为 AAC。',
]
CHILDREN = []
CANCELLED = False
PROTOCOL = sys.stdout
EMIT_LOCK = threading.RLock()


def emit(kind, **fields):
    with EMIT_LOCK:
        print(json.dumps({'type': kind, **fields}, ensure_ascii=False, allow_nan=False), file=PROTOCOL, flush=True)


def route_diagnostics():
    """Reserve the original stdout even when native libraries print to fd 1."""
    global PROTOCOL
    sys.stdout.flush()
    PROTOCOL = os.fdopen(os.dup(sys.stdout.fileno()), 'w', encoding='utf-8', buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    sys.stdout = sys.stderr


def terminate_children():
    for child in CHILDREN:
        if child.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                child.terminate()
    deadline = time.monotonic() + 3
    for child in CHILDREN:
        if child.poll() is None:
            try:
                child.wait(timeout=max(.01, deadline-time.monotonic()))
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    child.kill()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    child.wait(timeout=2)


def cancel(signum, _frame):
    global CANCELLED
    CANCELLED = True
    for child in CHILDREN:
        if child.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                child.terminate()
    raise KeyboardInterrupt()


def spawn(arguments, **kwargs):
    # Inherit the host's group. Never start_new_session, setsid, or killpg here.
    child = subprocess.Popen([str(value) for value in arguments], **kwargs)
    CHILDREN.append(child)
    return child


def boolean(value):
    if value.lower() in ('1', 'true', 'yes'):
        return True
    if value.lower() in ('0', 'false', 'no'):
        return False
    raise argparse.ArgumentTypeError('expected true or false')


def absolute_tool(value):
    path = Path(value).expanduser()
    if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError('FFmpeg / FFprobe 必须使用可执行文件的绝对路径')
    return str(path.resolve())


def probe(ffprobe, path, count_frames=False):
    command = [ffprobe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json']
    if count_frames:
        command += ['-count_frames']
    child = spawn(command + [path], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        stdout, stderr = child.communicate(timeout=120 if count_frames else 45)
    except subprocess.TimeoutExpired:
        child.kill(); child.communicate()
        raise RuntimeError('视频检查超时')
    if child.returncode:
        raise RuntimeError('视频检查失败：'+stderr.decode('utf-8', 'replace')[-1200:])
    if len(stdout) > 8*1024*1024:
        raise ValueError('视频元数据过大')
    data = json.loads(stdout)
    video = next((item for item in data.get('streams', []) if item.get('codec_type') == 'video'), None)
    if not video:
        raise ValueError('所选文件没有视频画面')
    width, height = int(video['width']), int(video['height'])
    rotation = float(video.get('tags', {}).get('rotate', 0))
    for item in video.get('side_data_list', []):
        if 'rotation' in item:
            rotation = float(item['rotation'])
    if round(abs(rotation)) % 180 == 90:
        width, height = height, width
    if round(rotation) % 90:
        raise ValueError('暂不支持非直角的画面旋转，请先导出为普通视频')
    rate = video.get('avg_frame_rate', '0/0')
    try:
        numerator, denominator = (int(number) for number in rate.split('/'))
        fps = numerator/denominator
        if not math.isfinite(fps) or not 0 < fps <= 240:
            raise ValueError()
    except (ValueError, ZeroDivisionError):
        raise ValueError('无法确定视频帧率，请先转换为普通 MP4')
    duration = float(video.get('duration') or data.get('format', {}).get('duration') or 0)
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError('无法确定视频时长，请先转换为普通 MP4')
    return {'width': width, 'height': height, 'rate': rate, 'fps': fps, 'duration': duration,
            'framesTotal': round(duration*fps),
            'decodedFrames': int(video.get('nb_read_frames', 0) or 0),
            'audioTracks': sum(item.get('codec_type') == 'audio' for item in data.get('streams', [])),
            'transfer': video.get('color_transfer'), 'sampleAspectRatio': video.get('sample_aspect_ratio', '1:1')}


def output_dimensions(width, height, mode):
    if mode == 'source':
        return width, height
    short, long = (720, 1280) if mode == 'hd720' else (1080, 1920)
    bound_w, bound_h = (long, short) if width >= height else (short, long)
    if width >= bound_w or height >= bound_h:
        return width, height
    numerator, denominator = (bound_w, width) if bound_w*height <= bound_h*width else (bound_h, height)
    return max(2, width*numerator//(2*denominator)*2), max(2, height*numerator//(2*denominator)*2)


def decode_dimensions(width, height, maximum):
    # Do not keep 96 full-resolution 4K source frames just to downsample in core.
    # This only resizes above the internal inference limit; final export sizing
    # follows the selected output mode and is reported separately.
    if max(width, height) <= maximum:
        return width, height
    factor = maximum/max(width, height)
    return max(2, int(width*factor)//2*2), max(2, int(height*factor)//2*2)


def fingerprint(path):
    stat = path.stat()
    return stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns


def publish_exclusive(source, destination):
    """Exclusive rename on Darwin; bounded exclusive copy on other filesystems.

    The host's private staging folder keeps the fallback copy out of the user's
    final export until the host verifies and publishes that folder.
    """
    if platform.system() == 'Darwin':
        library = ctypes.CDLL(None, use_errno=True)
        rename = library.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        # RENAME_EXCL from Apple's sys/stdio.h, available since macOS10.12.
        if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) == 0:
            return
        error = ctypes.get_errno()
        if error not in (errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENOSYS, errno.EINVAL, errno.EXDEV):
            raise OSError(error, os.strerror(error), str(destination))
    created = None
    try:
        with destination.open('xb') as target, source.open('rb') as original:
            created = (os.fstat(target.fileno()).st_dev, os.fstat(target.fileno()).st_ino)
            shutil.copyfileobj(original, target, length=1024*1024)
            target.flush()
            os.fsync(target.fileno())
        source.unlink()
    except BaseException:
        if created is not None:
            with contextlib.suppress(OSError):
                current = destination.stat()
                if (current.st_dev, current.st_ino) == created:
                    destination.unlink()
        raise


def diagnostic_log(original, state, verbose=False):
    """Keep long videos inside the host stderr budget without losing phases."""
    def log(message, *values, **options):
        for token, label in [('Phase 1:', '编码画面'), ('Phase 2:', '生成清晰纹理'),
                             ('Phase 3:', '还原画面'), ('Phase 4:', '混合时间重叠')]:
            if token in str(message):
                state['phase'] = label
        level = options.get('level', values[0] if values else 'INFO')
        if verbose or level in ('WARNING', 'ERROR'):
            original(message, *values, **options)
    return log


def sha256(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for part in iter(lambda: stream.read(8*1024*1024), b''):
            result.update(part)
    return result.hexdigest()


def validate_components(args):
    upstream = Path(args.upstream_dir).expanduser().resolve()
    models = Path(args.models_dir).expanduser().resolve()
    script = upstream/'inference_cli.py'
    if not script.is_file() or sha256(script) != CLI_SHA256:
        raise ValueError('SeedVR2 运行源码版本不匹配，请重新安装修复组件')
    for name in ('pos_emb.pt', 'neg_emb.pt', 'configs_3b/main.yaml',
                 'src/models/video_vae_v3/s8_c16_t4_inflation_sd3.yaml'):
        if not (upstream/name).is_file():
            raise ValueError('SeedVR2 运行组件缺少配置或文本嵌入，请重新安装组件')
    for name, (size, expected) in MODELS.items():
        model = models/name
        if not model.is_file() or model.stat().st_size != size:
            raise ValueError('SeedVR2 模型缺失或不完整，请先在飞羽中下载模型：'+name)
        if sha256(model) != expected:
            raise ValueError('SeedVR2 模型校验失败，请重新下载：'+name)
    return upstream, models


class MonitoredState(dict):
    publisher = None

    def __setitem__(self, key, value):
        super().__setitem__(key, value)
        if self.publisher and key != 'lastProgress':
            self.publisher(self)

    def update(self, *values, **fields):
        super().update(*values, **fields)
        if self.publisher:
            self.publisher(self)


class ResourceGuard:
    """Own an independent, Torch-free OS-resource and heartbeat subprocess."""
    def __init__(self, budget, state):
        import psutil
        self.storage = tempfile.TemporaryDirectory(prefix='feather-seed-guard-')
        self.directory = Path(self.storage.name)
        self.metrics = self.directory/'metrics.json'
        self.state_path = self.directory/'state.json'
        self.stop_path = self.directory/'stop'
        self.ready = self.directory/'ready.json'
        self.closed = False
        self.summary = {}
        self.state = state
        state.publisher = self.publish
        self.process = None
        self.publish(state)
        self.process = spawn([sys.executable, Path(__file__).resolve().with_name('resource_guard.py'),
                              '--parent-pid', os.getpid(), '--parent-start-time', repr(psutil.Process().create_time()),
                              '--state', self.state_path, '--metrics', self.metrics, '--stop-file', self.stop_path,
                              '--ready-file', self.ready, '--memory-budget', budget],
                             stdin=subprocess.DEVNULL, stdout=PROTOCOL, stderr=sys.stderr)
        deadline = time.monotonic()+5
        while not self.ready.exists() and self.process.poll() is None and time.monotonic() < deadline:
            time.sleep(.02)
        if not self.ready.exists() or self.process.poll() is not None:
            self.close(check=False)
            raise RuntimeError('独立资源监控未能启动，未开始模型推理')

    def publish(self, state):
        if self.closed:
            return
        if self.process is not None and self.process.poll() is not None:
            raise RuntimeError(self.reason or '独立资源监控已退出，停止本次修复')
        temporary = self.state_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(dict(state), ensure_ascii=False)+'\n', encoding='utf-8')
        temporary.replace(self.state_path)

    @property
    def reason(self):
        try:
            return json.loads(self.metrics.read_text(encoding='utf-8')).get('guardReason')
        except (OSError, ValueError):
            return self.summary.get('guardReason')

    def close(self, check=True):
        if self.closed:
            return
        self.closed = True
        self.state.publisher = None
        self.stop_path.touch()
        if self.process is not None:
            try:
                self.process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill(); self.process.wait(timeout=2)
            try:
                self.summary = json.loads(self.metrics.read_text(encoding='utf-8'))
            except (OSError, ValueError):
                self.summary = {}
        self.storage.cleanup()
        if check and self.summary.get('guardReason'):
            raise RuntimeError(self.summary['guardReason'])
        if check and (not self.summary.get('sampleCount') or self.process.returncode != 0):
            raise RuntimeError('独立资源监控未正常完成，导出未发布')


class SeedCore:
    def __init__(self, args, upstream, models, state, guard):
        # Force these values before importing torch or any upstream module.
        verbose = os.environ.get('FEATHER_SEEDVR2_DEBUG') == '1'
        os.environ.update(PYTORCH_ENABLE_MPS_FALLBACK='0', PYTORCH_MPS_HIGH_WATERMARK_RATIO='0.7',
                          PYTORCH_MPS_LOW_WATERMARK_RATIO='0.5', OMP_NUM_THREADS='4',
                          OPENBLAS_NUM_THREADS='4', VECLIB_MAXIMUM_THREADS='4',
                          HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', TQDM_DISABLE='0' if verbose else '1')
        import torch
        import cv2
        import numpy as np
        if platform.system() != 'Darwin' or platform.machine() != 'arm64' or not torch.backends.mps.is_available():
            raise ValueError('SeedVR2 本地组件需要 Apple Silicon 和可用的 MPS GPU，不会自动改用 CPU')
        if int(platform.mac_ver()[0].split('.')[0]) < 14:
            raise ValueError('SeedVR2 的 MPS BF16 推理需要 macOS 14 或更新版本')
        version = tuple(int(part) for part in torch.__version__.split('+')[0].split('.')[:2])
        if version < (2, 14):
            raise ValueError('SeedVR2 需要 PyTorch 2.14 或更新的已验收运行组件')
        torch.set_num_threads(4)
        torch.set_num_interop_threads(1)
        cv2.setNumThreads(1)
        self.torch, self.np, self.cv2 = torch, np, cv2
        spec = importlib.util.spec_from_file_location('feather_seedvr2_upstream', upstream/'inference_cli.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        # Importing the CLI only defines its entry point. We never call main(),
        # parse_args(), the video writer, or its implicit model downloader.
        def no_download(*_args, **_kwargs):
            raise RuntimeError('组件运行阶段禁止下载模型，请先在飞羽中完成下载')
        module.download_weight = no_download
        module_args = argparse.Namespace(
            dit_model='seedvr2_ema_3b_fp16.safetensors', model_dir=str(models),
            resolution=args.resolution, max_resolution=args.max_resolution,
            batch_size=args.batch_size, uniform_batch_size=True, seed=42, prepend_frames=0,
            temporal_overlap=args.temporal_overlap, cache_dit=False, cache_vae=False,
            dit_offload_device='none', vae_offload_device='none', tensor_offload_device='none',
            blocks_to_swap=0, swap_io_components=False, attention_mode='sdpa',
            vae_encode_tiled=True, vae_encode_tile_size=512, vae_encode_tile_overlap=64,
            vae_decode_tiled=True, vae_decode_tile_size=512, vae_decode_tile_overlap=64,
            tile_debug='false', compile_dit=False, compile_vae=False,
            color_correction='lab', input_noise_scale=0.0, latent_noise_scale=0.0)
        debug = module.Debug(enabled=False)
        debug.log = diagnostic_log(debug.log, state, verbose)
        self.module, self.args, self.debug = module, module_args, debug

    def __call__(self, frames):
        # Input and output remain bounded to one outer chunk. No whole video
        # accumulator. Core receives RGB float32 [T,H,W,C] exactly as upstream.
        array = self.np.stack(frames)
        tensor = self.torch.from_numpy(array[..., ::-1].copy()).to(self.torch.float32).div_(255)
        del array
        with self.torch.inference_mode():
            result = self.module._process_frames_core(tensor, self.args, 'mps', self.debug, runner_cache=None)
        del tensor
        if result.shape[0] != len(frames):
            raise RuntimeError(f'SeedVR2 返回帧数不匹配：{result.shape[0]} / {len(frames)}')
        if not self.torch.isfinite(result).all():
            raise RuntimeError('SeedVR2 返回了无效像素值')
        # Convert framewise: a second full float output copy is unnecessary.
        output = []
        for frame in result:
            rgb = frame.clamp(0, 1).mul(255).round().to(self.torch.uint8).numpy()
            output.append(self.np.ascontiguousarray(rgb[..., ::-1]))
        del result
        gc.collect()
        self.torch.mps.empty_cache()
        return output


def read_frame(stream, byte_count):
    pieces, remaining = [], byte_count
    while remaining:
        part = stream.read(remaining)
        if not part:
            if remaining == byte_count:
                return None
            raise RuntimeError('视频解码在一帧中途结束')
        pieces.append(part)
        remaining -= len(part)
    return b''.join(pieces)


def restore_stream(read, restore, write, chunk_size, overlap, on_chunk=None):
    """Hold real enhanced tail frames and crossfade with the next enhanced head.

    Windows contain at most chunk_size frames INCLUDING repeated raw context.
    Each original frame is written exactly once. No context-only prepend/crop.
    """
    raw_tail, pending = [], []
    read_count = written = chunks = 0
    while True:
        fresh = []
        for _ in range(chunk_size-len(raw_tail)):
            frame = read()
            if frame is None:
                break
            fresh.append(frame)
        if not fresh:
            for frame in pending:
                write(frame); written += 1
            break
        read_count += len(fresh)
        frames = raw_tail + fresh
        chunks += 1
        if on_chunk:
            on_chunk(chunks, read_count, len(frames))
        enhanced = restore(frames)
        if len(enhanced) != len(frames):
            raise RuntimeError('时间分块返回的帧数不匹配')
        if pending:
            import numpy as np
            for index, previous in enumerate(pending):
                following = enhanced[index]
                if previous.shape != following.shape:
                    raise RuntimeError('时间分块输出尺寸发生变化')
                alpha = (index+1)/(len(pending)+1)
                enhanced[index] = np.rint(previous.astype(np.float32)*(1-alpha)+following.astype(np.float32)*alpha).clip(0, 255).astype(np.uint8)
        hold = min(overlap, len(enhanced))
        end = len(enhanced)-hold
        for frame in enhanced[:end]:
            write(frame); written += 1
        pending = enhanced[end:]
        raw_tail = frames[-hold:] if hold else []
        del enhanced, frames, fresh
    if written != read_count:
        raise RuntimeError(f'整片帧数核验失败：读取 {read_count}，导出 {written}')
    return written, chunks


def repair(args):
    global CANCELLED
    source = Path(args.input).expanduser().resolve()
    destination = Path(args.output).expanduser().resolve()
    if not source.is_file():
        raise ValueError('原视频不存在')
    if source == destination or destination.exists():
        raise ValueError('导出路径必须是不存在的新文件，原视频未覆盖')
    if not args.enhance or args.repair_mosaic:
        raise ValueError('SeedVR2 只用于整体画质增强，请开启画质增强并关闭马赛克修复')
    if args.batch_size < 5 or args.batch_size > 33 or (args.batch_size-1) % 4:
        raise ValueError('batch-size 必须是 5 到 33 之间的 4n+1 帧')
    if not 0 < args.temporal_overlap < args.batch_size:
        raise ValueError('temporal-overlap 必须大于 0 且小于 batch-size')
    if not 33 <= args.chunk_size <= 96 or args.chunk_size <= 2*args.temporal_overlap:
        raise ValueError('chunk-size 必须为 33 到 96 帧，且大于两倍 overlap')
    if args.memory_budget < 20*GIB or args.memory_budget > 23*GIB:
        raise ValueError('SeedVR2 运行预算必须在 20 至 23 GiB 之间，不能沿用普通修复的内存预算')
    if args.resolution is None:
        args.resolution = 1080 if args.output_size == 'fullHD' else 720
    if args.resolution not in (720, 1080):
        raise ValueError('当前只支持 720 或 1080 内部推理尺寸')
    args.max_resolution = 1920 if args.resolution == 1080 else 1280
    args.ffmpeg, args.ffprobe = absolute_tool(args.ffmpeg), absolute_tool(args.ffprobe)
    meta = probe(args.ffprobe, source)
    if meta['width'] % 2 or meta['height'] % 2:
        raise ValueError('暂不支持奇数边长视频，请先转换为偶数分辨率')
    if meta['transfer'] in ('smpte2084', 'arib-std-b67'):
        raise ValueError('当前 SeedVR2 组件尚未验收 HDR 色彩转换，请先导出为 SDR 视频')
    if meta['sampleAspectRatio'] not in ('1:1', '0:1', 'N/A', None):
        raise ValueError('暂不支持非方形像素视频，请先导出为方形像素视频')
    source_stamp = fingerprint(source)
    ow, oh = output_dimensions(meta['width'], meta['height'], args.output_size)
    dw, dh = decode_dimensions(meta['width'], meta['height'], args.max_resolution)
    import psutil
    if psutil.virtual_memory().total < 32*GIB:
        raise ValueError('此 SeedVR2 组件需要至少 32 GiB 统一内存，当前设备尚未支持')
    if psutil.virtual_memory().available < 4*GIB:
        raise ValueError('当前可用内存不足 4 GiB，请关闭部分应用后重试')
    started = time.monotonic()
    state = MonitoredState(written=0, read=0, chunk=0, phase='校验本地模型',
                           started=started, framesTotal=meta['framesTotal'], performance=args.performance,
                           lastProgress=0.0)
    def progress(force=False):
        now = time.monotonic()
        if not force and now-state['lastProgress'] < 2:
            return
        # Only the guardian emits progress. The parent writes terminal events
        # after reaping it, so independent stdout writers cannot interleave JSON.
        guard.publish(state)
        state['lastProgress'] = now
    guard = ResourceGuard(args.memory_budget, state)
    progress(True)
    try:
        upstream, models = validate_components(args)
        core = SeedCore(args, upstream, models, state, guard)
        import numpy as np
        import cv2
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.feather-seedvr2-', dir=destination.parent) as temporary:
            temporary = Path(temporary)
            output = temporary/'output.mp4'
            with (temporary/'decode.log').open('w+') as decode_log, (temporary/'encode.log').open('w+') as encode_log:
                decoder = spawn([args.ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error', '-threads', '4',
                                 '-filter_threads', '2', '-i', source,
                                 '-map', '0:v:0', '-an', '-sn', '-vf', f'fps={meta["rate"]},scale={dw}:{dh}:flags=lanczos',
                                 '-f', 'rawvideo', '-pix_fmt', 'bgr24', 'pipe:1'],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=decode_log)
                bitrate = max(2_000_000, min(32_000_000, int(ow*oh*meta['fps']*.18)))
                encoder = spawn([args.ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error',
                                 '-f', 'rawvideo', '-pixel_format', 'bgr24', '-video_size', f'{ow}x{oh}',
                                 '-framerate', meta['rate'], '-i', 'pipe:0', '-i', source,
                                 '-map', '0:v:0', '-map', '1:a?', '-map_metadata', '1', '-metadata:s:v:0', 'rotate=0',
                                 '-c:v', 'h264_videotoolbox', '-allow_sw', '1', '-b:v', str(bitrate),
                                 '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart',
                                 '-f', 'mp4', output], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=encode_log)
                def read():
                    raw = read_frame(decoder.stdout, dw*dh*3)
                    return np.frombuffer(raw, np.uint8).reshape(dh, dw, 3).copy() if raw is not None else None
                def write(frame):
                    if frame.shape[1::-1] != (ow, oh):
                        frame = cv2.resize(frame, (ow, oh), interpolation=cv2.INTER_LANCZOS4)
                    try:
                        encoder.stdin.write(frame.tobytes())
                    except BrokenPipeError:
                        encode_log.seek(0)
                        raise RuntimeError('视频编码失败：'+encode_log.read()[-1200:])
                    state['written'] += 1
                def on_chunk(number, count, _size):
                    state.update(chunk=number, read=count, phase='准备时间分块')
                    progress(True)
                count, chunks = restore_stream(read, core, write, args.chunk_size, args.temporal_overlap, on_chunk)
                decoder.stdout.close()
                decoder.wait(timeout=60)
                if decoder.returncode:
                    decode_log.seek(0)
                    raise RuntimeError('视频解码失败：'+decode_log.read()[-1200:])
                if not count:
                    raise RuntimeError('未解码出视频画面')
                state.update(phase='保存并核验完整视频与音轨', stage='encoding', written=count)
                encoder.stdin.close()
                encoder.wait(timeout=120)
                if encoder.returncode:
                    encode_log.seek(0)
                    raise RuntimeError('视频导出失败：'+encode_log.read()[-1200:])
            actual = probe(args.ffprobe, output, count_frames=True)
            tolerance = max(.08, 2/meta['fps'])
            if (actual['width'], actual['height']) != (ow, oh) or actual['decodedFrames'] != count:
                raise RuntimeError('导出视频的画面方向、尺寸或完整帧数核验失败')
            if abs(actual['duration']-count/meta['fps']) > tolerance or abs(actual['fps']-meta['fps']) > .001:
                raise RuntimeError('导出视频帧率或时长核验失败')
            if actual['audioTracks'] != meta['audioTracks']:
                raise RuntimeError('导出视频音轨数量核验失败')
            if fingerprint(source) != source_stamp:
                raise RuntimeError('处理期间原视频发生变化，未发布导出文件')
            guard.close()
            publish_exclusive(output, destination)
        report = {'output': str(destination), 'framesProcessed': count, 'framesTotal': count,
                  'estimatedFramesTotal': meta['framesTotal'], 'regionsRepaired': 0, 'detectedFrames': 0,
                  'fps': meta['fps'], 'duration': actual['duration'], 'width': ow, 'height': oh,
                  'inputWidth': meta['width'], 'inputHeight': meta['height'], 'outputSize': args.output_size,
                  'audioTracks': actual['audioTracks'], 'enhance': True, 'repairMosaic': False,
                  'seconds': round(time.monotonic()-started, 2), 'performance': args.performance,
                  'enhancement': {'name': 'SeedVR2 3B FP16', 'device': 'mps', 'computeDtype': 'bfloat16',
                                  'upstreamRevision': REVISION, 'inferenceShortSide': args.resolution,
                                  'inferenceMaxEdge': args.max_resolution, 'batchSize': args.batch_size,
                                  'temporalOverlap': args.temporal_overlap, 'chunkFramesIncludingOverlap': args.chunk_size,
                                  'chunks': chunks, 'outerOverlapBlending': 'linear-output-crossfade',
                                  'tileSize': 512, 'tileOverlap': 64, 'automaticCPUFallback': False},
                  'pipeline': {'boundedInputFrames': args.chunk_size, 'heldEnhancedFrames': args.temporal_overlap,
                               'wholeVideoCached': False, 'intermediatePNGs': False, 'cpuThreads': 4},
                  'resources': dict(guard.summary), 'engines': {'enhance': 'SeedVR2 3B / PyTorch MPS BF16', 'local': None},
                  'limitations': LIMITATIONS}
        if args.report:
            Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        emit('completed', **report)
    except KeyboardInterrupt:
        if guard.reason:
            raise RuntimeError(guard.reason)
        raise
    finally:
        guard.close(check=False)
        terminate_children()


def self_test():
    """CPU-only installation/protocol checks; no model or MPS operation."""
    import io
    if not Path(__file__).resolve().with_name('resource_guard.py').is_file():
        raise RuntimeError('修复组件缺少独立资源监控程序')
    os.environ['TQDM_DISABLE'] = '1'
    import numpy as np
    import cv2
    import psutil
    import safetensors
    import torch
    version = tuple(int(part) for part in torch.__version__.split('+')[0].split('.')[:2])
    if version < (2, 14):
        raise RuntimeError('运行组件需要 PyTorch 2.14 或更新版本')
    tested = []
    for length in (0, 1, 2, 3, 4, 32, 33, 95, 96, 97, 186, 200):
        source = [np.full((2, 2, 3), index % 251, np.uint8) for index in range(length)]
        cursor = iter(source)
        result, windows = [], []
        def identity(frames):
            windows.append(len(frames))
            return [frame.copy() for frame in frames]
        count, chunks = restore_stream(lambda: next(cursor, None), identity, result.append, 96, 3)
        if count != length or len(result) != length or any(not np.array_equal(a, b) for a, b in zip(source, result)):
            raise RuntimeError(f'外层分块保序检查失败：{length}')
        if windows and max(windows) > 96:
            raise RuntimeError('外层分块超过内存边界')
        tested.append(length)
    # The second core result differs intentionally. A prepend-and-crop
    # implementation would produce no mixed pixels and fail this assertion.
    source = iter([np.zeros((2, 2, 3), np.uint8) for _ in range(97)])
    result, calls = [], [0]
    def changed(frames):
        calls[0] += 1
        return [np.full_like(frame, 100 if calls[0] == 1 else 200) for frame in frames]
    restore_stream(lambda: next(source, None), changed, result.append, 96, 3)
    if [int(result[index][0, 0, 0]) for index in range(93, 97)] != [125, 150, 175, 200]:
        raise RuntimeError('外层真实输出重叠混合检查失败')
    if read_frame(io.BytesIO(b'abcdef'), 6) != b'abcdef' or read_frame(io.BytesIO(b''), 6) is not None:
        raise RuntimeError('流式解码读取检查失败')
    try:
        read_frame(io.BytesIO(b'abc'), 6)
    except RuntimeError:
        pass
    else:
        raise RuntimeError('截断帧未被拒绝')
    if output_dimensions(540, 960, 'hd720') != (720, 1280) or output_dimensions(1080, 1920, 'hd720') != (1080, 1920):
        raise RuntimeError('720P 输出尺寸检查失败')
    logs, state = [], {}
    logger = diagnostic_log(lambda message, **_options: logs.append(message), state)
    for _ in range(10000):
        logger('forced normal info', force=True)
    logger('Phase 3: VAE decoding', force=True)
    logger('retained warning', level='WARNING', force=True)
    logger('retained error', level='ERROR', force=True)
    if logs != ['retained warning', 'retained error'] or state.get('phase') != '还原画面':
        raise RuntimeError('长视频日志抑制或阶段通知检查失败')
    from tqdm import tqdm
    buffer = io.StringIO()
    for _ in tqdm(range(3), file=buffer):
        pass
    if buffer.getvalue():
        raise RuntimeError('采样器进度条未被关闭')
    with tempfile.TemporaryDirectory(prefix='seed self test 空间 ') as temporary:
        first, target = Path(temporary)/'first', Path(temporary)/'target'
        first.write_bytes(b'first')
        publish_exclusive(first, target)
        if first.exists() or target.read_bytes() != b'first':
            raise RuntimeError('独占发布检查失败')
        first.write_bytes(b'second')
        try:
            publish_exclusive(first, target)
        except FileExistsError:
            pass
        else:
            raise RuntimeError('独占发布未拒绝已有目标')
        if first.read_bytes() != b'second' or target.read_bytes() != b'first':
            raise RuntimeError('独占发布覆盖了已有文件')
    child = spawn([sys.executable, '-c', 'import time; time.sleep(30)'], stdin=subprocess.DEVNULL,
                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if os.getpgid(child.pid) != os.getpgrp():
        raise RuntimeError('子进程未保留宿主进程组')
    terminate_children()
    if child.poll() is None:
        raise RuntimeError('子进程回收检查失败')
    emit('completed', selfTest=True, cpuOnly=True, modelsLoaded=False, gpuInference=False,
         checkedFrameCounts=tested, maximumWindowFrames=96, outputOverlapBlended=True,
         defaultWindowFrames=33, forcedInfoLogsSuppressed=10000, samplerProgressBarDisabled=True,
         exclusivePublicationVerified=True,
         childProcessGroupInherited=True, childProcessReaped=True,
         versions={'torch': torch.__version__, 'numpy': np.__version__, 'opencv': cv2.__version__,
                   'psutil': psutil.__version__, 'safetensors': safetensors.__version__})


def main():
    root_parser = argparse.ArgumentParser(description=__doc__)
    subcommands = root_parser.add_subparsers(dest='command', required=True)
    subcommands.add_parser('self-test', help='CPU-only dependency, protocol and streaming checks')
    parser = subcommands.add_parser('repair')
    for flag in ('input', 'output', 'ffmpeg', 'ffprobe', 'models-dir', 'upstream-dir'):
        parser.add_argument('--'+flag, required=True)
    parser.add_argument('--report')
    parser.add_argument('--enhance', type=boolean, default=True)
    parser.add_argument('--repair-mosaic', type=boolean, default=False)
    parser.add_argument('--performance', choices=('balanced', 'quality', 'quiet'), default='quality')
    parser.add_argument('--output-size', choices=('source', 'hd720', 'fullHD'), default='source')
    parser.add_argument('--memory-budget', type=int, default=23*GIB)
    parser.add_argument('--resolution', type=int)
    parser.add_argument('--batch-size', type=int, default=9)
    parser.add_argument('--chunk-size', type=int, default=33)
    parser.add_argument('--temporal-overlap', type=int, default=3)
    arguments = ['self-test'] if sys.argv[1:] == ['--self-test'] else sys.argv[1:]
    args = root_parser.parse_args(arguments)
    route_diagnostics()
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    try:
        self_test() if args.command == 'self-test' else repair(args)
    except KeyboardInterrupt:
        terminate_children()
        emit('cancelled', message='已取消，原视频未修改')
        return 130
    except Exception as error:
        terminate_children()
        traceback.print_exc(file=sys.stderr)
        emit('error', message=str(error))
        return 1
    finally:
        terminate_children()
    return 0


if __name__ == '__main__':
    sys.exit(main())
