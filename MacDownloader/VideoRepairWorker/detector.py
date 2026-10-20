"""Conservative, local grid evidence detector. No video or identity data leaves the Mac."""
from dataclasses import dataclass
import cv2
import numpy as np

@dataclass
class Region:
    x: int
    y: int
    width: int
    height: int
    confidence: float
    block_size: int

class MosaicDetector:
    """Detect repeated flat blocks in both image axes, with a bounded one-frame track.

    This detects pixelated mosaics, not every blur, opaque bar, watermark or natural
    square texture. A scene cut clears all history. Low confidence is counted and
    preserved rather than silently modifying possibly clean content.
    """
    def __init__(self):
        self.previous_gray = None
        self.previous_mask = None
        self.last_low_confidence = 0
        self.last_scene_cut = False
        self.missed_frames = 0

    def detect(self, image):
        h, w = image.shape[:2]
        scale = min(1.0, 960.0 / max(h, w))
        small = cv2.resize(image, (round(w * scale), round(h * scale)), interpolation=cv2.INTER_AREA) if scale < 1 else image
        gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY).astype(np.float32)
        sh, sw = gray.shape
        thumb = cv2.resize(gray, (64, 36))
        delta = float(np.mean(np.abs(thumb - self.previous_gray))) if self.previous_gray is not None else 255.0
        cut = self.previous_gray is not None and delta > 34
        self.previous_gray = thumb
        self.last_scene_cut = cut
        if cut:
            self.previous_mask = None
        self.last_low_confidence = 0
        votes = np.zeros((sh, sw), np.float32)
        block_map = np.zeros((sh, sw), np.float32)
        win, stride = 32, 8
        if min(sh, sw) < win:
            return [], np.zeros((h, w), np.uint8)
        # A derivative profile across an actual mosaic has regularly spaced spikes.
        dx = np.abs(np.diff(gray, axis=1))
        dy = np.abs(np.diff(gray, axis=0))
        # Calculate window statistics in native code, then compare all eligible
        # derivative profiles together. No skipped frames or sampled detection:
        # this evaluates exactly the same 32x32 windows as the scalar scan.
        ys, xs = np.mgrid[0:sh-win+1:stride, 0:sw-win+1:stride]
        def sums(array, height, width):
            integral = cv2.integral(array.astype(np.float64))
            return (integral[ys+height, xs+width] - integral[ys, xs+width]
                    - integral[ys+height, xs] + integral[ys, xs])
        flat = (sums(dx < 3.5, win, win-1) + sums(dy < 3.5, win-1, win)) / (2*win*(win-1))
        mean = sums(gray, win, win)/(win*win)
        variance = np.maximum(0, sums(gray.astype(np.float64)**2, win, win)/(win*win)-mean**2)
        eligible = (flat >= .77) & (variance >= 81)
        cy, cx = ys[eligible], xs[eligible]
        if len(cx):
            # Prefix sums along the perpendicular axis give each 31-element
            # derivative profile without materialising N full window images.
            dx_sum = np.pad(np.cumsum(dx, axis=0, dtype=np.float64), ((1,0),(0,0)))
            dy_sum = np.pad(np.cumsum(dy, axis=1, dtype=np.float64), ((0,0),(1,0)))
            offsets = np.arange(win-1)
            ex = ((dx_sum[cy[:,None]+win,cx[:,None]+offsets]
                   - dx_sum[cy[:,None],cx[:,None]+offsets])/win).astype(np.float32)
            ey = ((dy_sum[cy[:,None]+offsets,cx[:,None]+win]
                   - dy_sum[cy[:,None]+offsets,cx[:,None]])/win).astype(np.float32)
            strong = (ex.max(axis=1) >= 10) & (ey.max(axis=1) >= 10)
            cy,cx,ex,ey = cy[strong],cx[strong],ex[strong],ey[strong]
            flats = flat[eligible][strong]
            ex -= ex.mean(axis=1,keepdims=True)
            ey -= ey.mean(axis=1,keepdims=True)
            best = np.zeros(len(cx),np.float32)
            periods = np.zeros(len(cx),np.int32)
            for p in range(4,13):
                def correlation(profiles):
                    a,b = profiles[:,:-p],profiles[:,p:]
                    return np.sum(a*b,axis=1)/(np.sqrt(np.sum(a*a,axis=1)*np.sum(b*b,axis=1))+1e-6)
                score = np.minimum(correlation(ex),correlation(ey))
                better = score > best
                best[better],periods[better] = score[better],p
            accepted = (best >= .65) & (periods >= 6)
            self.last_low_confidence += int(np.count_nonzero((~accepted) & (best > .4)))
            for y,x,score,period,flatness in zip(cy[accepted],cx[accepted],best[accepted],periods[accepted],flats[accepted]):
                patch = votes[y:y+win,x:x+win]
                np.maximum(patch,min(1.0,.55*float(score)+.45*float(flatness)),out=patch)
                block_map[y:y+win,x:x+win] = period
        raw = (votes >= .58).astype(np.uint8) * 255
        raw = cv2.morphologyEx(raw, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
        # Keep current evidence; bridge only a one-frame detector dropout in an
        # almost unchanged scene. Never carry a mosaic into the next shot.
        if np.any(raw):
            if self.previous_mask is not None and not cut and delta < 6:
                overlap = cv2.bitwise_and(self.previous_mask, cv2.dilate(raw, np.ones((9,9), np.uint8)))
                raw = cv2.bitwise_or(raw, overlap)
            self.missed_frames = 0
        elif self.previous_mask is not None and not cut and delta < 1.5 and self.missed_frames == 0:
            raw = self.previous_mask.copy()
            # Retained regions carry the last high-confidence evidence.
            votes[raw > 0] = .6
            block_map[raw > 0] = 8
            self.missed_frames = 1
        else:
            self.missed_frames += 1
        self.previous_mask = raw.copy()
        n, labels, stats, _ = cv2.connectedComponentsWithStats(raw)
        out_mask = np.zeros((h, w), np.uint8)
        regions = []
        for i in range(1, n):
            x, y, rw, rh, area = (int(a) for a in stats[i])
            if area < 180 or min(rw, rh) < 20:
                continue
            selected = labels[y:y+rh, x:x+rw] == i
            confidence = float(np.mean(votes[y:y+rh, x:x+rw][selected]))
            b = int(np.median(block_map[y:y+rh, x:x+rw][selected]))
            # Tighten the coarse sliding-window proposal to actual flat grid
            # cells. This avoids blurring an extra half-window around a mosaic.
            patch = gray[y:y+rh, x:x+rw]
            b = max(4, b)
            gx = np.mean(np.abs(np.diff(patch, axis=1)), axis=0)
            gy = np.mean(np.abs(np.diff(patch, axis=0)), axis=1)
            phase_x = max(range(b), key=lambda p: float(np.mean(gx[p::b])) if gx[p::b].size else 0)
            phase_y = max(range(b), key=lambda p: float(np.mean(gy[p::b])) if gy[p::b].size else 0)
            cells = np.zeros((rh, rw), np.uint8)
            for cy in range((phase_y+1)%b, rh-b+1, b):
                for cx in range((phase_x+1)%b, rw-b+1, b):
                    cell = patch[cy+1:cy+b-1, cx+1:cx+b-1]
                    if cell.size == 0 or np.std(cell) > 5.5:
                        continue
                    edges = []
                    if cx>0: edges.append(float(np.mean(np.abs(patch[cy:cy+b,cx]-patch[cy:cy+b,cx-1]))))
                    if cx+b<rw: edges.append(float(np.mean(np.abs(patch[cy:cy+b,cx+b]-patch[cy:cy+b,cx+b-1]))))
                    if cy>0: edges.append(float(np.mean(np.abs(patch[cy,cx:cx+b]-patch[cy-1,cx:cx+b]))))
                    if cy+b<rh: edges.append(float(np.mean(np.abs(patch[cy+b,cx:cx+b]-patch[cy+b-1,cx:cx+b]))))
                    if sum(v>5 for v in edges)>=2 and max(edges,default=0)>10:
                        cells[cy:cy+b,cx:cx+b]=255
            nonzero=cv2.findNonZero(cells)
            if nonzero is None:
                self.last_low_confidence += 1
                continue
            tx,ty,tw,th=cv2.boundingRect(nonzero)
            if min(tw,th)<16:
                continue
            x,y,rw,rh=x+tx,y+ty,tw,th
            ox, oy = max(0, int(x/scale)), max(0, int(y/scale))
            ow, oh = min(w-ox, int(np.ceil(rw/scale))), min(h-oy, int(np.ceil(rh/scale)))
            regions.append(Region(ox, oy, ow, oh, round(confidence, 3), max(4, round(b/scale))))
            out_mask[oy:oy+oh, ox:ox+ow] = 255
        return regions, out_mask
