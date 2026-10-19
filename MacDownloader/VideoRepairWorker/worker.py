#!/usr/bin/env python3
"""Offline, streaming video post-processing worker for Feather.

stdout is an NDJSON protocol; diagnostic output belongs on stderr. The app starts
this process in its own process group. All children stay in that group, and TERM
also explicitly terminates children. Work storage is bounded by a frame and tile.
"""
from __future__ import annotations
import argparse
import contextlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import traceback

# Set before importing torch; an unsupported MPS operation can fall back safely.
os.environ.setdefault('PYTORCH_ENABLE_MPS_FALLBACK', '1')
os.environ.setdefault('OMP_NUM_THREADS', '4')
os.environ.setdefault('OPENBLAS_NUM_THREADS', '4')
import cv2
import numpy as np
from detector import MosaicDetector

ROOT = Path(__file__).resolve().parent
CHILDREN = []
CANCELLED = False
LIMITATIONS = [
    '局部修复为 AI 推测补画，无法恢复已丢失的真实细节，也不保证身份或文字准确。',
    '自动检测针对规则像素马赛克，可能漏检或误检；模糊、纯色遮挡和不规则打码不保证识别。',
    '逐帧修复可能出现纹理闪烁；输出保留原尺寸，HDR 会转换为 SDR。',
]

def emit(kind, **fields):
    print(json.dumps({'type': kind, **fields}, ensure_ascii=False), flush=True)

def cancelled(signum, _frame):
    global CANCELLED
    CANCELLED = True
    for process in CHILDREN:
        with contextlib.suppress(ProcessLookupError):
            process.terminate()
    raise KeyboardInterrupt()

signal.signal(signal.SIGTERM, cancelled)
signal.signal(signal.SIGINT, cancelled)

def spawn(args, **kwargs):
    proc = subprocess.Popen([str(a) for a in args], **kwargs)
    CHILDREN.append(proc)
    return proc

def boolean(text):
    if text.lower() in ('true', '1', 'yes'):
        return True
    if text.lower() in ('false', '0', 'no'):
        return False
    raise argparse.ArgumentTypeError('expected true or false')

def metadata(ffprobe, path):
    proc = subprocess.run([ffprobe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)], capture_output=True, text=True, check=True, timeout=45)
    meta = json.loads(proc.stdout)
    video = next((s for s in meta['streams'] if s['codec_type'] == 'video'), None)
    if video is None:
        raise ValueError('所选文件没有视频画面')
    w, h = int(video['width']), int(video['height'])
    rotation = next((int(float(s.get('rotation', 0))) for s in video.get('side_data_list', []) if 'rotation' in s), 0)
    if abs(rotation) % 180 == 90:
        w, h = h, w
    rate = video.get('avg_frame_rate', '0/0')
    try:
        num, den = rate.split('/')
        fps = float(num) / float(den)
        if not 0 < fps <= 240:
            raise ValueError()
    except (ValueError, ZeroDivisionError):
        rate, fps = '30/1', 30.0
    duration = float(video.get('duration') or meta.get('format', {}).get('duration') or 0)
    if duration <= 0:
        raise ValueError('无法确定视频时长，请先转换为普通 MP4')
    return {'width':w, 'height':h, 'fps':fps, 'rate':rate, 'duration':duration,
            'framesTotal':round(duration*fps), 'audioTracks':sum(s['codec_type']=='audio' for s in meta['streams'])}

class Enhancement:
    """Resident official general-x4v3 model with bounded 4x tile intermediates."""
    tile_size = 256
    tile_pad = 34
    whole_frame_limit = 512

    def __init__(self):
        import torch
        from srvgg_arch import SRVGGNetCompact
        self.torch = torch
        torch.set_num_threads(min(4, os.cpu_count() or 4))
        self.model = SRVGGNetCompact(num_in_ch=3, num_out_ch=3, num_feat=64,
                                    num_conv=32, upscale=4, act_type='prelu')
        weights = torch.load(ROOT/'models'/'realesr-general-x4v3.pth',
                             map_location='cpu', weights_only=True)
        self.model.load_state_dict(weights.get('params_ema', weights.get('params', weights)), strict=True)
        self.model.eval()
        self.device = 'mps' if torch.backends.mps.is_available() else 'cpu'
        self.devices_used = set()
        self.fallback_count = 0
        self.fallback_reasons = []
        self.tiles_processed = 0
        self.frames_processed = 0
        try:
            self.model.to(self.device)
        except Exception as error:
            self.fallback(error)

    def fallback(self, error):
        if self.device != 'mps':
            raise error
        self.fallback_count += 1
        if len(self.fallback_reasons) < 4:
            self.fallback_reasons.append(str(error)[-300:])
        self.device = 'cpu'
        self.model.to('cpu')
        with contextlib.suppress(Exception):
            self.torch.mps.empty_cache()

    def infer(self, tile):
        rgb = cv2.cvtColor(tile, cv2.COLOR_BGR2RGB)
        tensor = self.torch.from_numpy(np.ascontiguousarray(rgb.transpose(2,0,1))).float().div_(255).unsqueeze(0)
        try:
            with self.torch.inference_mode():
                result = self.model(tensor.to(self.device))
                if self.device == 'mps':
                    self.torch.mps.synchronize()
                result = result[0].permute(1,2,0).cpu().numpy()
        except Exception as error:
            # Retry the complete tile on CPU; no partly computed GPU tile is
            # written into the output, and subsequent tiles stay on CPU.
            self.fallback(error)
            with self.torch.inference_mode():
                result = self.model(tensor)[0].permute(1,2,0).numpy()
        self.devices_used.add(self.device)
        self.tiles_processed += 1
        result = np.clip(np.rint(result*255), 0, 255).astype(np.uint8)
        return cv2.cvtColor(result, cv2.COLOR_RGB2BGR)

    def process(self, image, on_tile):
        h,w = image.shape[:2]
        if max(h,w) <= self.whole_frame_limit:
            result = cv2.resize(self.infer(image), (w,h), interpolation=cv2.INTER_AREA)
            on_tile(1,1)
        else:
            result = np.empty_like(image)
            total = math.ceil(w/self.tile_size)*math.ceil(h/self.tile_size)
            count = 0
            for y0 in range(0,h,self.tile_size):
                for x0 in range(0,w,self.tile_size):
                    x1,y1 = min(w,x0+self.tile_size),min(h,y0+self.tile_size)
                    sx,sy = max(0,x0-self.tile_pad),max(0,y0-self.tile_pad)
                    ex,ey = min(w,x1+self.tile_pad),min(h,y1+self.tile_pad)
                    up = self.infer(image[sy:ey,sx:ex])
                    # All 34 surrounding source pixels are available to the
                    # 34-convolution network before cropping the tile core.
                    core = up[(y0-sy)*4:(y1-sy)*4,(x0-sx)*4:(x1-sx)*4]
                    result[y0:y1,x0:x1] = cv2.resize(core,(x1-x0,y1-y0),interpolation=cv2.INTER_AREA)
                    count += 1
                    on_tile(count,total)
        self.frames_processed += 1
        return result

    def report(self):
        return {'device':self.device, 'devicesUsed':sorted(self.devices_used),
                'fallbackCount':self.fallback_count, 'fallbackReasons':self.fallback_reasons,
                'tileSize':self.tile_size, 'tilePad':self.tile_pad,
                'wholeFrameLimit':self.whole_frame_limit, 'tilesProcessed':self.tiles_processed,
                'framesEnhanced':self.frames_processed}

class LocalRepair:
    def __init__(self):
        import torch
        self.torch = torch
        torch.set_num_threads(min(4, os.cpu_count() or 4))
        # LaMa relies on FFT. CPU is the portable path on Apple Silicon; SRVGG
        # independently uses MPS for global enhancement.
        self.model = torch.jit.load(str(ROOT/'models'/'big-lama.pt'), map_location='cpu').eval()
        self.detector = MosaicDetector()
        self.regions = 0
        self.detected_frames = 0
        self.low_confidence = 0
        self.cuts = 0
        self.samples = []

    def process(self, image, frame_number):
        regions, _ = self.detector.detect(image)
        self.low_confidence += self.detector.last_low_confidence
        self.cuts += int(self.detector.last_scene_cut)
        self.detected_frames += int(bool(regions))
        original = image.copy()
        for r in regions:
            # Context is needed for inpainting. Bounded crops avoid loading a
            # high-resolution whole frame into a large neural network.
            margin = max(32, min(160, max(r.width,r.height)//2))
            x0,y0 = max(0,r.x-margin), max(0,r.y-margin)
            x1,y1 = min(image.shape[1],r.x+r.width+margin), min(image.shape[0],r.y+r.height+margin)
            crop = original[y0:y1,x0:x1].copy()
            scale = min(1.0, 512/max(crop.shape[:2]))
            ch,cw = crop.shape[:2]
            work = cv2.resize(crop,(max(8,round(cw*scale)),max(8,round(ch*scale))),interpolation=cv2.INTER_AREA) if scale<1 else crop
            wh,ww = work.shape[:2]
            rx,ry = round((r.x-x0)*scale),round((r.y-y0)*scale)
            rw,rh = min(ww-rx,round(r.width*scale)),min(wh-ry,round(r.height*scale))
            if min(rw,rh)<8:
                continue
            b = max(3, round(r.block_size*scale))
            gray = cv2.cvtColor(work[ry:ry+rh,rx:rx+rw],cv2.COLOR_BGR2GRAY).astype(np.float32)
            gx=np.mean(np.abs(np.diff(gray,axis=1)),axis=0)
            gy=np.mean(np.abs(np.diff(gray,axis=0)),axis=1)
            phase_x=max(range(b),key=lambda p:float(np.mean(gx[p::b])) if gx[p::b].size else 0)
            phase_y=max(range(b),key=lambda p:float(np.mean(gy[p::b])) if gy[p::b].size else 0)
            yy,xx=np.mgrid[:rh,:rw]
            strip=max(1,b//4)
            distance_x=np.minimum((xx-phase_x)%b,(phase_x-xx)%b)
            distance_y=np.minimum((yy-phase_y)%b,(phase_y-yy)%b)
            grid=((distance_x<=strip)|(distance_y<=strip)).astype(np.uint8)*255
            mask=np.zeros((wh,ww),np.uint8)
            mask[ry:ry+rh,rx:rx+rw]=grid
            # Pad to modulo eight, as required by the released TorchScript model.
            ph,pw=(-wh)%8,(-ww)%8
            rgb=cv2.cvtColor(work,cv2.COLOR_BGR2RGB)
            rgb=cv2.copyMakeBorder(rgb,0,ph,0,pw,cv2.BORDER_REFLECT_101)
            padded=cv2.copyMakeBorder(mask,0,ph,0,pw,cv2.BORDER_CONSTANT)
            tensor=self.torch.from_numpy(np.ascontiguousarray(rgb.transpose(2,0,1))).float().div_(255).unsqueeze(0)
            mt=self.torch.from_numpy((padded>0).astype(np.float32)).unsqueeze(0).unsqueeze(0)
            with self.torch.inference_mode():
                result=self.model(tensor,mt)[0].permute(1,2,0).cpu().numpy()
            result=cv2.cvtColor(np.clip(result[:wh,:ww]*255,0,255).astype(np.uint8),cv2.COLOR_RGB2BGR)
            result=cv2.resize(result,(cw,ch),interpolation=cv2.INTER_CUBIC)
            # Preserve the input's low-frequency colours and silhouette. The
            # network supplies proposed detail/edges rather than erasing a
            # masked person or object into background.
            sigma=max(1.2,r.block_size*.65)
            low=cv2.GaussianBlur(crop.astype(np.float32),(0,0),sigma)
            generated=result.astype(np.float32)
            detail=generated-cv2.GaussianBlur(generated,(0,0),sigma)
            repaired=np.clip(low+.75*detail,0,255)
            alpha=np.zeros((ch,cw),np.float32)
            alpha[r.y-y0:r.y-y0+r.height,r.x-x0:r.x-x0+r.width]=1
            alpha=cv2.GaussianBlur(alpha,(0,0),max(1,r.block_size*.35))[:,:,None]
            image[y0:y1,x0:x1]=np.clip(image[y0:y1,x0:x1]*(1-alpha)+repaired*alpha,0,255).astype(np.uint8)
            self.regions+=1
            if len(self.samples)<200:
                self.samples.append({'frame':frame_number,'x':r.x,'y':r.y,'width':r.width,'height':r.height,'confidence':r.confidence,'blockSize':r.block_size})
        return image

def read_frame(stream, size):
    chunks=[]
    remaining=size
    while remaining:
        data=stream.read(remaining)
        if not data:
            if remaining==size:
                return None
            raise RuntimeError('视频解码在一帧中途结束')
        chunks.append(data)
        remaining-=len(data)
    return b''.join(chunks)

def repair(args):
    source=Path(args.input).expanduser().resolve()
    destination=Path(args.output).expanduser().resolve()
    if source==destination:
        raise ValueError('导出路径必须与原视频不同')
    if destination.exists():
        raise ValueError('导出路径已存在，原文件未覆盖')
    if not args.enhance and not args.repair_mosaic:
        raise ValueError('请至少开启一种修复功能')
    meta=metadata(args.ffprobe,source)
    destination.parent.mkdir(parents=True,exist_ok=True)
    w,h=meta['width'],meta['height']
    if w%2 or h%2:
        raise ValueError('此版本暂不支持奇数边长视频，请先转换为偶数分辨率')
    emit('progress',progress=.01,stage='prepare',message='准备本地 AI 模型',framesProcessed=0,framesTotal=meta['framesTotal'],regionsRepaired=0)
    local=LocalRepair() if args.repair_mosaic else None
    enhancement=Enhancement() if args.enhance else None
    frame_count=0
    started=time.monotonic()
    last_progress=0.0
    with tempfile.TemporaryDirectory(prefix='.feiyu-ai-', dir=destination.parent) as tmp:
        temp=Path(tmp)
        decoded_log=(temp/'decode.log').open('w+')
        encoded_log=(temp/'encode.log').open('w+')
        # ffmpeg normalises variable frame rate to the source's average rate;
        # the parent verifies duration/audio/orientation before final commit.
        decoder=spawn([args.ffmpeg,'-hide_banner','-loglevel','error','-i',source,'-map','0:v:0','-an','-sn','-vf','fps='+meta['rate'],'-f','rawvideo','-pix_fmt','bgr24','pipe:1'],stdout=subprocess.PIPE,stderr=decoded_log)
        encoder=spawn([args.ffmpeg,'-hide_banner','-loglevel','error','-f','rawvideo','-pixel_format','bgr24','-video_size',f'{w}x{h}','-framerate',meta['rate'],'-i','pipe:0','-i',source,'-map','0:v:0','-map','1:a?','-map_metadata','1','-metadata:s:v:0','rotate=0','-c:v','h264_videotoolbox','-allow_sw','1','-b:v',str(max(2_000_000,min(24_000_000,w*h*meta['fps']*.14))),'-pix_fmt','yuv420p','-c:a','aac','-b:a','192k','-movflags','+faststart','-f','mp4',destination],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=encoded_log)
        raw_size=w*h*3
        while True:
            raw=read_frame(decoder.stdout,raw_size)
            if raw is None:
                break
            image=np.frombuffer(raw,np.uint8).reshape(h,w,3).copy()
            if local:
                image=local.process(image,frame_count)
            if time.monotonic()-last_progress >= 2:
                progress=.04+.90*min(.999,(frame_count+(.35 if enhancement else .90))/max(1,meta['framesTotal']))
                emit('progress',progress=progress,stage='preparing',message=f'整片识别与局部 AI 修复 · 已准备 {frame_count+1} 帧' if local else f'准备画质增强 · 已读取 {frame_count+1} 帧',framesProcessed=frame_count,framesPrepared=frame_count+1,framesTotal=meta['framesTotal'],regionsRepaired=local.regions if local else 0)
                last_progress=time.monotonic()
            if enhancement:
                def enhancement_progress(done,total):
                    nonlocal last_progress
                    if time.monotonic()-last_progress >= 2:
                        progress=.04+.90*min(.999,(frame_count+.35+.55*done/total)/max(1,meta['framesTotal']))
                        emit('progress',progress=progress,stage='enhancing',message=f'AI 画质增强 · 第 {frame_count+1} 帧 · 分块 {done}/{total}',framesProcessed=frame_count,framesPrepared=frame_count+1,framesEnhanced=enhancement.frames_processed,framesTotal=meta['framesTotal'],regionsRepaired=local.regions if local else 0)
                        last_progress=time.monotonic()
                image=enhancement.process(image,enhancement_progress)
            try:
                encoder.stdin.write(image.tobytes())
            except BrokenPipeError:
                encoded_log.seek(0)
                raise RuntimeError('视频编码失败：'+encoded_log.read()[-1500:])
            frame_count+=1
            progress=.04+.90*min(.999,frame_count/max(1,meta['framesTotal']))
            if time.monotonic()-last_progress >= 2:
                emit('progress',progress=progress,stage='processing',message='整片自动识别与 AI 修复' if args.repair_mosaic else '整片 AI 画质增强',framesProcessed=frame_count,framesTotal=meta['framesTotal'],regionsRepaired=local.regions if local else 0)
                last_progress=time.monotonic()
        decoder.stdout.close();decoder.wait()
        if decoder.returncode:
            decoded_log.seek(0)
            raise RuntimeError('视频解码失败：'+decoded_log.read()[-1500:])
        if not frame_count:
            raise RuntimeError('未解码出视频画面')
        emit('progress',progress=.95,stage='encoding',message='保存完整视频与音轨',framesProcessed=frame_count,framesTotal=meta['framesTotal'],regionsRepaired=local.regions if local else 0)
        encoder.stdin.close();encoder.wait()
        if encoder.returncode:
            encoded_log.seek(0)
            raise RuntimeError('视频导出失败：'+encoded_log.read()[-1500:])
    report={'output':str(destination),'framesProcessed':frame_count,'framesTotal':frame_count,'estimatedFramesTotal':meta['framesTotal'],'regionsRepaired':local.regions if local else 0,'detectedFrames':local.detected_frames if local else 0,'lowConfidenceCandidates':local.low_confidence if local else 0,'sceneCuts':local.cuts if local else 0,'samples':local.samples if local else [],'fps':meta['fps'],'duration':meta['duration'],'width':w,'height':h,'audioTracks':meta['audioTracks'],'enhance':args.enhance,'repairMosaic':args.repair_mosaic,'enhancement':enhancement.report() if enhancement else None,'seconds':round(time.monotonic()-started,2),'engines':{'enhance':'Real-ESRGAN general x4v3 / PyTorch '+enhancement.device.upper() if enhancement else None,'local':'LaMa TorchScript, grid-edge inpainting + original low-frequency constraint' if args.repair_mosaic else None},'limitations':LIMITATIONS}
    if args.report:
        Path(args.report).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    emit('completed',**{key:value for key,value in report.items() if key not in ('samples',)})

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('repair')
    p.add_argument('--input',required=True);p.add_argument('--output',required=True)
    p.add_argument('--ffmpeg',required=True);p.add_argument('--ffprobe',required=True)
    p.add_argument('--enhance',type=boolean,default=True)
    p.add_argument('--repair-mosaic',type=boolean,default=True)
    p.add_argument('--report')
    args=parser.parse_args()
    try:
        repair(args)
    except KeyboardInterrupt:
        emit('cancelled',message='已取消，原视频未修改')
        return 130
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        emit('error',message=str(error))
        return 1
    finally:
        for child in CHILDREN:
            if child.poll() is None:
                with contextlib.suppress(ProcessLookupError):child.terminate()
        for child in CHILDREN:
            if child.poll() is None:
                try: child.wait(timeout=2)
                except subprocess.TimeoutExpired:child.kill()
    return 0

if __name__=='__main__':
    sys.exit(main())
