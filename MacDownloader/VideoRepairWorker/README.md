# Feather offline video repair worker

This Python subprocess scans the entire video. There are no manual ranges or
user-selected rectangles. All media stays on the local computer. An Apple Silicon
Python runtime, PyTorch, OpenCV, the LaMa TorchScript model and official Real-ESRGAN general-x4v3
model are packaged by `MacDownloader/scripts/fetch-video-repair.py`.

Run `python/bin/python3 worker.py repair --input input.mp4 --output new.mp4
--ffmpeg /path/to/ffmpeg --ffprobe /path/to/ffprobe --enhance true
--repair-mosaic true --report details.json`. Standard output is NDJSON with
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
Results downsample to source resolution. This is not an upscaling feature.
HDR is exported as SDR H.264.

The pipeline retains one original/output frame, a bounded LaMa crop, and a bounded
4x SRVGG intermediate. Frames with maximum edge <=512 run whole; larger frames
use 256-pixel tile cores plus 34 source pixels of surrounding context (the full
34-convolution receptive radius). Each core downsamples and writes directly into
the original-resolution frame, avoiding a 4x full-frame allocation. No PNG batch
or external enhancement subprocess is created. Progress updates every two seconds
with prepared/exported frame counts kept separate. Input average frame rate is
used for CFR export; the host verifies duration, frame count, audio-track count
and display orientation before marking success. All source audio tracks are
mapped to AAC. Output is a new MP4. No full-video frame extraction is retained.

Third-party notices and source URLs are in the runtime `licenses` directory and
`manifest.json`. The new detector and wrapper do not incorporate DeepMosaics code,
weights or adult-specific models. LaMa uses Apache-2.0; Real-ESRGAN and its SRVGG architecture use BSD-3-Clause. Dependency distribution licenses are retained in
Python packages and their `dist-info` folders. The bundled source remains readable.
