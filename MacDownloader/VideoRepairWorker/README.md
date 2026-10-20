# Feather offline video repair worker

This Python subprocess scans the entire video. There are no manual ranges or
user-selected rectangles. All media stays on the local computer. An Apple Silicon
Python runtime, PyTorch, OpenCV, the LaMa TorchScript model and official Real-ESRGAN general-x4v3
and RRDB x2plus/x4plus models are packaged by `MacDownloader/scripts/fetch-video-repair.py`.

Run `python/bin/python3 worker.py repair --input input.mp4 --output new.mp4
--ffmpeg /path/to/ffmpeg --ffprobe /path/to/ffprobe --enhance true
--repair-mosaic true --performance balanced --output-size source --report details.json`. Standard output is NDJSON with
`type=progress/completed/error/cancelled`. Progress is 0..1. The Swift host keeps
100% for its final video validation and atomic commit. Source media is never
overwritten. TERM/INT stops the active subprocess and its children. The host must
also terminate the dedicated process group if a native model does not respond.

The detector uses local two-axis periodic grid evidence and flat block interiors,
with scene-cut reset. Multiple regions are evaluated on each frame. Low-confidence
patches are counted and preserved. This is a conservative pixel-grid detector;
it is not a universal censor, blur, text or watermark detector.

The local model is LaMa, a general image inpainting model. Grid-edge bands are
reconstructed from surrounding context. Input low-frequency colour and silhouette
constrain the blend so a masked subject is not simply deleted into background.
Generated texture can be wrong and is not recovered original information. Faces,
identity, text and plate numbers are not verifiable. Per-frame processing may
flicker. Real-ESRGAN general-x4v3 enhances each complete frame with the official
SRVGGNetCompact network (64 channels,32 convolutions,PReLU,4x). The network remains
resident on Apple MPS. On MPS failure the complete affected tile retries on CPU,
and further tiles remain on CPU; fallback devices and reasons are reported.
For `--output-size source`, results downsample to source resolution.
HDR is exported as SDR H.264.

The ordered CPU preparation thread detects/repairs every frame with one detector
history; a queue of at most four prepared frame jobs overlaps it with MPS enhancement.
Up to four CPU jobs share one read-only LaMa model with one native thread each;
the worker count reduces to two/one at lower memory budgets. Ordered detection
and ordered future consumption preserve detector history and output frame order.
FFmpeg decodes and encodes independently through bounded pipes. There is one copy
of each model, no eight-process duplication and no full-video frame extraction.
GPU enhancement uses FP16, 512-pixel tile cores and 34 source pixels of context
(the full receptive radius). Quantisation and 4x-to-source area reduction happen
on GPU before transfer. MPS failure retries the entire tile on FP32 CPU and keeps
subsequent tiles on CPU; source quality and fallback reasons are reported.

`--performance balanced` (the default) limits enhancement inference to a 960-pixel
long edge, then adds the resized AI residual to the original source frame. It
preserves native output dimensions and source high-frequency detail, but makes a
quality/speed tradeoff compared with native-resolution AI inference. `quality`
uses native resolution. `quiet` limits enhancement to 640, uses one CPU job and two native threads
instead of up to four jobs with one native thread each, and inserts bounded cooldowns in both CPU and GPU stages. LaMa
crop dimensions and per-frame detection remain the same in all modes. This is a
load reduction policy, not a guarantee about fan noise or thermal conditions.

Progress reports exported frames, measured throughput and estimated remaining
time every two seconds, including while the GPU waits for CPU inpainting. Input
average frame rate is used for CFR export. The host verifies duration, frame
count, audio-track count and display orientation before marking success. All
source audio tracks map to AAC; the new MP4 uses the selected output dimensions.

Model-backed regression checks:
`FEATHER_REPAIR_RUNTIME=/absolute/runtime/path runtime/python/bin/python3 -B
-m unittest discover -s MacDownloader/Tests/VideoRepairWorkerTests -v`.

Third-party notices and source URLs are in the runtime `licenses` directory and
`manifest.json`. The new detector and wrapper do not incorporate DeepMosaics code,
weights or adult-specific models. LaMa uses Apache-2.0; Real-ESRGAN and its SRVGG architecture use BSD-3-Clause. Dependency distribution licenses are retained in
Python packages and their `dist-info` folders. The bundled source remains readable.

`--output-size fullHD` enables native RRDB neural super-resolution without
pre-reducing input frames. It fits the display-oriented aspect ratio within
1920x1080 (landscape) or 1080x1920 (portrait), rounds down to even dimensions,
and never reduces higher-resolution input. Aspect ratio is preserved to within
even-pixel rounding; nonstandard aspects need not be exactly 1920x1080.
Targets above 2x choose official RealESRGAN_x4plus; others choose x2plus.
Both have 23 RRDB blocks. The x2 model uses pixel-unshuffle; tile origins align
to its even source phase and odd edges are reflect-padded. Core size is 256;
context is 128 source pixels for x2 and 64 for x4. Small frames can use one
inference, with scale-aware edge and output-area limits. One resident model
uses MPS FP16 with pristine FP32 CPU retry on failure. No tile geometry changes
during a retry. CPU preparation is limited to at most two jobs/queued frames.

Full HD quality mode requires substantially more computation than the tiny
SRVGG fast path. It is explicitly selected, and the existing source-size default
is retained. Dimensions alone do not prove detail quality; generated detail can
be wrong and temporal texture can flicker. RRDB architecture is adapted from
BasicSR under Apache-2.0; release weights use Real-ESRGAN BSD-3-Clause.
