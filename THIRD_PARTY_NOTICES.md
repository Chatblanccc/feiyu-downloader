# Third-party source notices

The repository's root [MIT license](LICENSE) applies to original Feiyu project
code. Third-party code, model weights, and dependencies retain their respective
licenses; the root license does not replace those terms.

## BasicSR RRDB architecture

[`rrdb_arch.py`](MacDownloader/VideoRepairWorker/rrdb_arch.py) is adapted from
the official [BasicSR RRDB architecture](https://github.com/XPixelGroup/BasicSR/blob/master/basicsr/archs/rrdbnet_arch.py)
under Apache License 2.0. The adaptation removes registry and training-only
initialization plumbing and retains the network's forward calculations. All
learned parameters are loaded strictly from the official evaluation checkpoints.

The complete license is included at
[`MacDownloader/VideoRepairWorker/BasicSR-LICENSE.txt`](MacDownloader/VideoRepairWorker/BasicSR-LICENSE.txt).
The upstream license is available from
[BasicSR](https://github.com/XPixelGroup/BasicSR/blob/master/LICENSE.txt).

## Real-ESRGAN

[`srvgg_arch.py`](MacDownloader/VideoRepairWorker/srvgg_arch.py) is adapted from
the official [Real-ESRGAN SRVGG architecture](https://github.com/xinntao/Real-ESRGAN/blob/master/realesrgan/archs/srvgg_arch.py)
under the BSD 3-Clause license. Its BasicSR registry import and decorator are
removed. The Real-ESRGAN general-x4v3 and RRDB x2plus/x4plus model checkpoints
retain the Real-ESRGAN release license and attribution.

The complete license is included at
[`MacDownloader/VideoRepairWorker/Real-ESRGAN-LICENSE.txt`](MacDownloader/VideoRepairWorker/Real-ESRGAN-LICENSE.txt).
See the official [Real-ESRGAN repository](https://github.com/xinntao/Real-ESRGAN)
and [upstream license](https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE).

## Packaged runtime and source archive

The offline application's AI runtime includes complete notices in
`Contents/Resources/VideoRepair/licenses/`, including
`BasicSR-Apache-2.0.txt`, `Real-ESRGAN-BSD-3-Clause.txt`, and
`THIRD-PARTY-NOTICES.txt`. During a local build these files reside in
`work/vendor/video-repair/licenses/`. Pinned model source URLs and checksums are
recorded by [`fetch-video-repair.py`](MacDownloader/scripts/fetch-video-repair.py)
and the generated runtime `manifest.json`.

The delivered source archive also includes these license texts under
`ThirdPartyNotices/VideoRepair/`. Other packaged dependencies retain their
licenses and notices in the application's corresponding resource directories
and the source archive's `ThirdPartyNotices/` directory.
