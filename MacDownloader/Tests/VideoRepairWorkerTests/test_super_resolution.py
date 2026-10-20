"""Geometry, real-model seams and complete-tile fallback for Full HD export.

Run sequentially with the bundled Python and FEATHER_REPAIR_RUNTIME. The only
real footage used here is the repository's public MDN CC0 flower fixture.
"""
import contextlib
import gc
import hashlib
import math
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import cv2
import numpy as np
import torch

SOURCE = Path(__file__).resolve().parents[2] / 'VideoRepairWorker'
REPO = SOURCE.parent.parent
sys.path.insert(0, str(SOURCE))
from super_resolution import SuperResolution, output_dimensions

RUNTIME = Path(os.environ['FEATHER_REPAIR_RUNTIME']).resolve()
GIB = 1024 ** 3


class GeometryTests(unittest.TestCase):
    def test_full_hd_geometry_preserves_aspect_orientation_and_large_sources(self):
        cases = [
            ((480, 270), (1920, 1080)),
            ((270, 480), (1080, 1920)),
            ((960, 540), (1920, 1080)),
            ((1280, 720), (1920, 1080)),
            ((640, 480), (1440, 1080)),
            ((480, 640), (1080, 1440)),
            ((720, 720), (1080, 1080)),
            ((854, 480), (1920, 1078)),
            ((1920, 1080), (1920, 1080)),
            ((3840, 2160), (3840, 2160)),
            ((2560, 720), (2560, 720)),
        ]
        for source, expected in cases:
            with self.subTest(source=source):
                actual = output_dimensions(*source, 'fullHD')
                self.assertEqual(actual, expected)
                self.assertEqual(actual[0] % 2, 0)
                self.assertEqual(actual[1] % 2, 0)
                self.assertEqual(output_dimensions(*source, 'source'), source)
        with self.assertRaises(ValueError):
            output_dimensions(480, 270, 'invalid')

    def _without_weights(self, source, target, budget):
        # These contract tests inspect the real constructor/assembler without
        # loading 64 MB checkpoints; model-backed tests below use real weights.
        with patch('rrdb_arch.RRDBNet', return_value=torch.nn.Identity()), \
             patch.object(torch, 'load', return_value={'params': {}}), \
             patch.object(torch.backends.mps, 'is_available', return_value=False):
            return SuperResolution(RUNTIME, source, target, memory_budget=budget)

    def test_scale_selection_and_budget_contract(self):
        for source, target, scale, edge, pad in [
            ((480, 270), (1920, 1080), 4, 512, 64),
            ((960, 540), (1920, 1080), 2, 1024, 128),
            ((1280, 720), (1920, 1080), 2, 1024, 128),
        ]:
            for budget, native_pixels in [(2 * GIB, 1_048_576), (4 * GIB, 4_194_304)]:
                with self.subTest(source=source, budget=budget):
                    engine = self._without_weights(source, target, budget)
                    self.assertEqual(engine.scale, scale)
                    self.assertEqual(engine.whole_frame_limit, edge)
                    self.assertEqual(engine.tile_pad, pad)
                    self.assertEqual(engine.whole_frame_native_pixels, native_pixels)

    def test_native_pixel_budget_selects_full_or_tiled_path(self):
        image = np.full((270, 480, 3), 79, np.uint8)
        for budget, expected_tiles in [(2 * GIB, 4), (4 * GIB, 1)]:
            with self.subTest(budget=budget):
                engine = self._without_weights((480, 270), (1920, 1080), budget)
                callbacks = []
                # Nearest expansion is used only to identify coverage/path and
                # preserve an easy-to-check unique value in every output pixel.
                with patch.object(engine, 'infer', side_effect=lambda im: im.repeat(4, 0).repeat(4, 1)):
                    actual = engine.process(image, lambda *v: callbacks.append(v))
                self.assertEqual(actual.shape, (1080, 1920, 3))
                self.assertTrue(np.all(actual == 79))
                self.assertEqual(len(callbacks), expected_tiles)
                self.assertEqual(callbacks[-1], (expected_tiles, expected_tiles))


class ModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(2)
        cv2.setNumThreads(1)
        fixture = REPO / 'work/validation/v0.5.0/samples/flower-original.mp4'
        if not fixture.is_file():
            raise unittest.SkipTest('Public MDN CC0 flower fixture unavailable')
        capture = cv2.VideoCapture(str(fixture))
        capture.set(cv2.CAP_PROP_POS_FRAMES, 75)
        ok, cls.flower = capture.read()
        capture.release()
        if not ok:
            raise unittest.SkipTest('Cannot decode public CC0 flower fixture')

    def tearDown(self):
        gc.collect()
        with contextlib.suppress(Exception):
            torch.mps.empty_cache()

    def test_official_checkpoints_match_pinned_provenance(self):
        expected = {
            'RealESRGAN_x2plus.pth': '49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb',
            'RealESRGAN_x4plus.pth': '4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1',
        }
        for name, digest in expected.items():
            with self.subTest(model=name):
                self.assertEqual(hashlib.sha256((RUNTIME / 'models' / name).read_bytes()).hexdigest(), digest)

    def test_real_x2_and_x4_tiled_frames_match_full_within_one_level(self):
        for scale in (2, 4):
            with self.subTest(scale=scale):
                image = self.flower if scale == 2 else cv2.resize(self.flower, (480, 270), interpolation=cv2.INTER_AREA)
                h, w = image.shape[:2]
                engine = SuperResolution(RUNTIME, (w, h), (w * scale, h * scale), memory_budget=6 * GIB)
                expected = engine.process(image, lambda *_: None)
                engine.whole_frame_limit = 0
                callbacks = []
                actual = engine.process(image, lambda *v: callbacks.append(v))
                difference = np.abs(expected.astype(int) - actual.astype(int))
                self.assertLessEqual(int(difference.max()), 1)
                self.assertLess(float(difference.mean()), .05)
                expected_count = math.ceil(w / 256) * math.ceil(h / 256)
                self.assertEqual(len(callbacks), expected_count)
                self.assertEqual(callbacks[-1], (expected_count, expected_count))
                self.assertEqual(engine.frames_processed, 2)
                del engine
                gc.collect()
                with contextlib.suppress(Exception):
                    torch.mps.empty_cache()

    def test_x2_odd_input_and_odd_tile_step_keep_global_pixel_unshuffle_phase(self):
        # Odd tile steps deliberately produce odd unaligned context origins;
        # preserving the global phase is essential for the x2 model's unshuffle.
        image = self.flower[80:241, 200:585].copy()  # 161 x 385, both odd
        h, w = image.shape[:2]
        engine = SuperResolution(RUNTIME, (w, h), (2 * w, 2 * h), memory_budget=6 * GIB)
        expected = engine.process(image, lambda *_: None)
        self.assertEqual(expected.shape, (322, 770, 3))
        engine.whole_frame_limit, engine.tile_size = 0, 129
        actual = engine.process(image, lambda *_: None)
        difference = np.abs(expected.astype(int) - actual.astype(int))
        self.assertLessEqual(int(difference.max()), 1)
        self.assertLess(float(difference.mean()), .05)

    def test_mid_frame_fallback_reloads_pristine_fp32_and_preserves_tile_coverage(self):
        engine = SuperResolution(RUNTIME, (144, 80), (288, 160), memory_budget=6 * GIB)
        if engine.device != 'mps':
            self.skipTest('MPS hardware required for injected GPU fallback')
        image = self.flower[120:200, 350:494].copy()
        engine.whole_frame_limit, engine.tile_size = 0, 64
        pristine = engine.pristine_state['conv_first.weight'].clone()
        # Confirm this fixture would catch mere half-to-float promotion.
        self.assertFalse(torch.equal(pristine, pristine.half().float()))
        original_forward = engine.model.forward
        devices = []

        def fail_second_tile(tensor):
            devices.append(tensor.device.type)
            if len(devices) == 2:
                raise RuntimeError('injected MPS tile failure')
            return original_forward(tensor)

        callbacks = []
        with patch.object(engine.model, 'forward', side_effect=fail_second_tile):
            actual = engine.process(image, lambda *v: callbacks.append(v))
        self.assertEqual(devices[:3], ['mps', 'mps', 'cpu'])
        self.assertTrue(all(device == 'cpu' for device in devices[2:]))
        self.assertEqual(engine.device, 'cpu')
        self.assertEqual(engine.dtype, torch.float32)
        self.assertEqual(engine.fallback_count, 1)
        self.assertEqual(engine.tile_size, 64)
        self.assertEqual(engine.tiles_processed, 6)
        self.assertEqual(callbacks, [(n, 6) for n in range(1, 7)])
        self.assertTrue(torch.equal(engine.model.state_dict()['conv_first.weight'], pristine))
        expected = engine.infer(image)
        self.assertEqual(actual.shape, expected.shape)
        self.assertLessEqual(int(np.abs(actual.astype(int) - expected.astype(int)).max()), 1)


if __name__ == '__main__':
    unittest.main()
