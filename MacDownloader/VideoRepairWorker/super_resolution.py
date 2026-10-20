"""Resident RRDB super-resolution, preserving neural pixels through Full HD export.

Weights/architecture are from the official Real-ESRGAN/BasicSR releases. One GPU
model and bounded inference tiles are retained; no full-video extraction occurs.
"""
from __future__ import annotations
import contextlib
import math
from pathlib import Path

import cv2
import numpy as np


def output_dimensions(width, height, output_size):
    if output_size == 'source':
        return width,height
    if output_size != 'fullHD':
        raise ValueError('Unknown output size')
    bw,bh = (1920,1080) if width >= height else (1080,1920)
    if width >= bw or height >= bh:
        return width,height
    numerator,denominator = (bw,width) if bw*height <= bh*width else (bh,height)
    return max(2,width*numerator//(2*denominator)*2),max(2,height*numerator//(2*denominator)*2)


class SuperResolution:
    tile_size = 256
    tile_pad = 64
    whole_frame_limit = 512

    def __init__(self, root, source_size, target_size, performance='quality', memory_budget=2*1024**3):
        import torch
        from rrdb_arch import RRDBNet
        self.torch = torch
        self.target_size = tuple(target_size)
        self.scale = 4 if max(target_size[0]/source_size[0],target_size[1]/source_size[1]) > 2 else 2
        self.name = f'RealESRGAN_x{self.scale}plus'
        self.tile_pad = 128 if self.scale == 2 else 64
        self.whole_frame_limit = 1024 if self.scale == 2 else 512
        self.whole_frame_native_pixels = 4_194_304 if memory_budget >= 4*1024**3 else 1_048_576
        self.performance = performance
        self.model = RRDBNet(num_in_ch=3,num_out_ch=3,num_feat=64,num_block=23,num_grow_ch=32,scale=self.scale)
        weights = torch.load(Path(root)/'models'/(self.name+'.pth'),map_location='cpu',weights_only=True)
        self.pristine_state = weights.get('params_ema',weights.get('params',weights))
        self.model.load_state_dict(self.pristine_state,strict=True)
        self.model.eval()
        self.device = 'mps' if torch.backends.mps.is_available() else 'cpu'
        self.dtype = torch.float16 if self.device == 'mps' else torch.float32
        self.devices_used = set()
        self.fallback_count = 0
        self.fallback_reasons = []
        self.tiles_processed = 0
        self.frames_processed = 0
        try:
            self.model.to(device=self.device,dtype=self.dtype)
        except Exception as error:
            self.fallback(error)

    def fallback(self, error):
        if self.device != 'mps':
            raise error
        self.fallback_count += 1
        if len(self.fallback_reasons) < 4:
            self.fallback_reasons.append(str(error)[-300:])
        self.device,self.dtype = 'cpu',self.torch.float32
        self.model.to(device='cpu',dtype=self.dtype)
        # Reload pristine FP32 parameters, rather than promoting rounded FP16.
        self.model.load_state_dict(self.pristine_state,strict=True)
        with contextlib.suppress(Exception):
            self.torch.mps.empty_cache()

    def infer(self, tile):
        h,w = tile.shape[:2]
        # x2 uses pixel-unshuffle and therefore requires even input dimensions.
        pad_h,pad_w = (-h)%2,(-w)%2
        padded = cv2.copyMakeBorder(tile,0,pad_h,0,pad_w,cv2.BORDER_REFLECT_101)
        rgb = cv2.cvtColor(padded,cv2.COLOR_BGR2RGB)
        tensor = self.torch.from_numpy(np.ascontiguousarray(rgb.transpose(2,0,1))).unsqueeze(0)
        def forward():
            with self.torch.inference_mode():
                result = self.model(tensor.to(device=self.device,dtype=self.dtype).div_(255))
                if not bool(self.torch.isfinite(result).all()):
                    raise RuntimeError('AI 模型返回非有限值')
                result = result[0,:,:h*self.scale,:w*self.scale].float().clamp_(0,1).mul_(255).round_()
                return result.permute(1,2,0).to(self.torch.uint8).cpu().numpy()
        try:
            result = forward()
        except Exception as error:
            self.fallback(error)
            result = forward()
        self.devices_used.add(self.device)
        self.tiles_processed += 1
        return cv2.cvtColor(result,cv2.COLOR_RGB2BGR)

    def process(self, image, on_tile):
        h,w = image.shape[:2]
        ow,oh = self.target_size
        enlarging = ow > w or oh > h
        if max(w,h) <= self.whole_frame_limit and w*h*self.scale**2 <= self.whole_frame_native_pixels:
            result = self.infer(image)
            if result.shape[:2] != (oh,ow):
                interpolation = cv2.INTER_AREA if ow < result.shape[1] else cv2.INTER_LANCZOS4
                result = cv2.resize(result,(ow,oh),interpolation=interpolation)
            self.frames_processed += 1
            on_tile(1,1)
            return result
        # An enlarging frame fits Full HD, so this native RGB assembly is bounded
        # by <4K RGB (~25MB). High-res originals reduce each neural tile directly
        # to its source-sized core and never allocate an oversized whole frame.
        result = np.empty((h*self.scale,w*self.scale,3),np.uint8) if enlarging else np.empty_like(image)
        total = math.ceil(w/self.tile_size)*math.ceil(h/self.tile_size)
        count = 0
        for y0 in range(0,h,self.tile_size):
            for x0 in range(0,w,self.tile_size):
                x1,y1 = min(w,x0+self.tile_size),min(h,y0+self.tile_size)
                sx,sy = max(0,x0-self.tile_pad),max(0,y0-self.tile_pad)
                ex,ey = min(w,x1+self.tile_pad),min(h,y1+self.tile_pad)
                # Align RRDB x2 pixel-unshuffle phase with the global frame.
                sx,sy = sx-sx%2,sy-sy%2
                up = self.infer(image[sy:ey,sx:ex])
                core = up[(y0-sy)*self.scale:(y1-sy)*self.scale,(x0-sx)*self.scale:(x1-sx)*self.scale]
                if enlarging:
                    result[y0*self.scale:y1*self.scale,x0*self.scale:x1*self.scale] = core
                else:
                    result[y0:y1,x0:x1] = cv2.resize(core,(x1-x0,y1-y0),interpolation=cv2.INTER_AREA)
                count += 1
                on_tile(count,total)
        if enlarging and result.shape[:2] != (oh,ow):
            interpolation = cv2.INTER_AREA if ow < result.shape[1] else cv2.INTER_LANCZOS4
            result = cv2.resize(result,(ow,oh),interpolation=interpolation)
        self.frames_processed += 1
        return result

    def report(self):
        gpu_memory = {}
        with contextlib.suppress(Exception):
            if self.torch.backends.mps.is_available():
                gpu_memory = {'mpsTensorBytesAtCompletion':self.torch.mps.current_allocated_memory(),
                              'mpsDriverBytesAtCompletion':self.torch.mps.driver_allocated_memory()}
        return {**gpu_memory,'model':self.name,'modelScale':self.scale,'device':self.device,'devicesUsed':sorted(self.devices_used),
                'precision':str(self.dtype),'fallbackCount':self.fallback_count,'fallbackReasons':self.fallback_reasons,
                'tileSize':self.tile_size,'tilePad':self.tile_pad,'wholeFrameLimit':self.whole_frame_limit,'tilesProcessed':self.tiles_processed,
                'wholeFrameNativePixelLimit':self.whole_frame_native_pixels,'framesEnhanced':self.frames_processed,'outputSize':list(self.target_size),
                'inferenceMaxEdge':None,'fusion':'neural super-resolution, no input downscale',
                'performance':self.performance}
