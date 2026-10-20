"""Model-backed checks. Run with the bundled Python and FEATHER_REPAIR_RUNTIME."""
import contextlib
import importlib.util
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from concurrent.futures import ThreadPoolExecutor

import cv2
import numpy as np
import torch

SOURCE = Path(__file__).resolve().parents[2]/'VideoRepairWorker'
sys.path.insert(0,str(SOURCE))
import worker
worker.ROOT = Path(os.environ['FEATHER_REPAIR_RUNTIME']).resolve()

class EnhancementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(2)
        cls.enhancement = worker.Enhancement('quality')
        cls.image = np.random.default_rng(42).integers(0,256,(80,112,3),dtype=np.uint8)

    def test_tile_context_prevents_seams(self):
        e = self.enhancement
        expected = e.process(self.image,lambda *_:None)
        old_limit,old_size = e.whole_frame_limit,e.tile_size
        try:
            e.whole_frame_limit,e.tile_size = 0,40
            actual = e.process(self.image,lambda *_:None)
        finally:
            e.whole_frame_limit,e.tile_size = old_limit,old_size
        self.assertLessEqual(np.abs(expected.astype(float)-actual).max(),1)

    def test_gpu_half_matches_original_fp32_quantise_and_downsample(self):
        e = self.enhancement
        if e.device != 'mps':
            self.skipTest('MPS hardware required for half precision comparison')
        from srvgg_arch import SRVGGNetCompact
        reference = SRVGGNetCompact(num_conv=32).eval()
        reference.load_state_dict({k:v.float().cpu() for k,v in e.model.state_dict().items()})
        # Reload original full precision weights, rather than comparing against
        # an already rounded half model.
        weights = torch.load(worker.ROOT/'models/realesr-general-x4v3.pth',map_location='cpu',weights_only=True)
        reference.load_state_dict(weights.get('params_ema',weights.get('params',weights)))
        rgb = cv2.cvtColor(self.image,cv2.COLOR_BGR2RGB)
        x = torch.from_numpy(rgb.transpose(2,0,1).copy()).float().div_(255).unsqueeze(0)
        with torch.inference_mode():
            y = reference(x)[0].permute(1,2,0).numpy()
        y = np.clip(np.rint(y*255),0,255).astype(np.uint8)
        expected = cv2.cvtColor(cv2.resize(y,(112,80),interpolation=cv2.INTER_AREA),cv2.COLOR_RGB2BGR)
        actual = e.process(self.image,lambda *_:None)
        delta = np.abs(expected.astype(float)-actual)
        self.assertLessEqual(delta.max(),3)
        self.assertLess(delta.mean(),.15)

    def test_fast_mode_fuses_residual_and_preserves_original_dimensions(self):
        e = self.enhancement
        old_edge = e.max_edge
        seen = []
        def identity(image,callback):
            seen.append(image.shape)
            return image.copy()
        try:
            e.max_edge = 64
            with patch.object(e,'process_native',side_effect=identity):
                result = e.process(self.image,lambda *_:None)
        finally:
            e.max_edge = old_edge
        self.assertEqual(max(seen[0][:2]),64)
        np.testing.assert_array_equal(result,self.image)

    def test_mps_failure_retries_entire_tile_on_fp32_cpu(self):
        e = worker.Enhancement('quality')
        if e.device != 'mps':
            self.skipTest('MPS hardware required for fallback test')
        forward = e.model.forward
        calls = []
        def fail_once(tensor):
            calls.append(str(tensor.device))
            if len(calls)==1:
                raise RuntimeError('injected MPS failure')
            return forward(tensor)
        with patch.object(e.model,'forward',side_effect=fail_once):
            result = e.process(self.image,lambda *_:None)
        self.assertEqual(result.shape,self.image.shape)
        self.assertEqual(e.device,'cpu')
        self.assertEqual(e.dtype,torch.float32)
        self.assertEqual(e.fallback_count,1)
        self.assertEqual(len(calls),2)
        self.assertTrue(np.isfinite(result).all())

    def test_mid_frame_fallback_preserves_tile_step_and_every_output_pixel(self):
        e = worker.Enhancement('quality')
        if e.device != 'mps':
            self.skipTest('MPS hardware required for fallback test')
        e.tile_size,e.whole_frame_limit = 512,0
        image = np.random.default_rng(91).integers(0,256,(32,1200,3),dtype=np.uint8)
        forward = e.model.forward
        calls = []
        def fail_once(tensor):
            calls.append(str(tensor.device))
            if len(calls)==1:
                raise RuntimeError('injected first-tile MPS failure')
            return forward(tensor)
        with patch.object(e.model,'forward',side_effect=fail_once):
            actual = e.process(image,lambda *_:None)
        self.assertEqual(e.tile_size,512)
        self.assertEqual(e.tiles_processed,3)
        expected = e.process(image,lambda *_:None)
        np.testing.assert_array_equal(actual,expected)

class DetectorTests(unittest.TestCase):
    def test_grid_detection_and_scene_reset(self):
        detector = worker.MosaicDetector()
        rng = np.random.default_rng(71)
        image = np.full((180,320,3),25,np.uint8)
        blocks = rng.integers(30,220,(10,10,3),dtype=np.uint8)
        image[40:120,80:160] = cv2.resize(blocks,(80,80),interpolation=cv2.INTER_NEAREST)
        regions,mask = detector.detect(image)
        self.assertGreater(len(regions),0)
        self.assertGreater(np.count_nonzero(mask[40:120,80:160]),2000)
        regions,mask = detector.detect(np.full_like(image,240))
        self.assertTrue(detector.last_scene_cut)
        self.assertEqual(regions,[])
        self.assertEqual(np.count_nonzero(mask),0)

    def test_parallel_lama_uses_one_model_and_preserves_frame_results(self):
        torch.set_num_threads(1)
        local = worker.LocalRepair()
        image = np.full((128,160,3),25,np.uint8)
        blocks = np.random.default_rng(71).integers(30,220,(10,10,3),dtype=np.uint8)
        image[24:104,40:120] = cv2.resize(blocks,(80,80),interpolation=cv2.INTER_NEAREST)
        regions = local.detect_regions(image)
        self.assertGreater(len(regions),0)
        frames = [np.clip(image.astype(int)+i*2,0,255).astype(np.uint8) for i in range(8)]
        expected = [local.process(frame.copy(),i,regions) for i,frame in enumerate(frames)]
        before = local.regions
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(local.process,frame.copy(),i,regions) for i,frame in enumerate(frames)]
            actual = [future.result(timeout=20) for future in futures]
        for a,b in zip(actual,expected):
            np.testing.assert_array_equal(a,b)
        self.assertEqual(local.regions,2*before)

if __name__=='__main__':
    unittest.main()
