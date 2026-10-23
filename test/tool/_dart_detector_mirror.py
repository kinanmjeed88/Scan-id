"""Faithful Python reference mirror of the Scan-id boundary pipeline:
- `lib/imaging/document_detector.dart` (`_fineSide = 1200`, `_coarseSide = 480`)
- `lib/imaging/document_segmenter.dart` (`segmentDecoded` + `_segmentEnclosedMultiCards`)
- `lib/domain/quad_assessment.dart` (`assessQuad`)
- `lib/domain/boundary_decision.dart` (`verifyBoundary`)
- `lib/imaging/hybrid_boundary_arbitrator.dart` (`measureQuadPhysics`, `arbitrateSceneBoundaries`, `arbitrateSingleBoundary`)

Honesty note on cross-runtime fidelity:
- All algorithmic logic, thresholds, coordinate formulas `(w - 1)` / `(h - 1)`,
  Hough quantization, structure tensor eigenvalues, Otsu binning, morphology,
  polygon clipping, and decision gates mirror the Dart source 1-to-1.
- Downsampling uses `PIL.Image.Resampling.BOX` as a close floating-point model
  of `package:image` `copyResize(..., interpolation: Interpolation.average)`.
  Because the Dart/Flutter SDK is not installed in this Linux sandbox, integer
  JPEG DCT / box-resize rounding differences (~0..1 gray levels) can only be
  confirmed end-to-end inside `flutter test` on CI; resampling perturbation
  sensitivity (`BOX` vs `BILINEAR`) is explicitly tested in `test_document_boundary_pipeline.py`.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np
from PIL import Image, ImageOps

COARSE_SIDE = 480
FINE_SIDE = 1200  # Matches `maxRecognitionPreviewLongEdge = 1200` in `lib/domain/image_limits.dart`
SEGMENT_WORK_SIDE = 360
ENCLOSED_WORK_SIDE = 720
MAX_PLAUSIBLE_REGION_ASPECT = 8.0
MIN_USABLE_REGION_CROP_PX = 48
MAX_SEGMENT_CANDIDATES = 12
MAX_ASPECT_CLAIM_RATIO = 2.5
SHAPE_TOLERANCE = 0.04


# ---------------------------------------------------------------------------
# Polygon & Geometry Helpers (`quad_assessment.dart` / `boundary_decision.dart`)
# ---------------------------------------------------------------------------


def _cross2(ax: float, ay: float, bx: float, by: float, cx: float, cy: float) -> float:
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)


def signed_polygon_area(poly: Sequence[Tuple[float, float]]) -> float:
    s = 0.0
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        s += x1 * y2 - x2 * y1
    return 0.5 * s


def polygon_area_abs(poly: Sequence[Tuple[float, float]]) -> float:
    return abs(signed_polygon_area(poly))


def clip_convex_polygon(
    subject: Sequence[Tuple[float, float]], clip: Sequence[Tuple[float, float]]
) -> List[Tuple[float, float]]:
    clipped = list(subject)
    orient = 1.0 if signed_polygon_area(clip) >= 0.0 else -1.0
    m = len(clip)
    for edge in range(m):
        if not clipped:
            break
        e1x, e1y = clip[edge]
        e2x, e2y = clip[(edge + 1) % m]

        def side(pt: Tuple[float, float]) -> float:
            return orient * ((e2x - e1x) * (pt[1] - e1y) - (e2y - e1y) * (pt[0] - e1x))

        nxt: List[Tuple[float, float]] = []
        k = len(clipped)
        for i in range(k):
            cur = clipped[i]
            prev = clipped[(i - 1) % k]
            cs, ps = side(cur), side(prev)
            ci, pi = cs >= 0.0, ps >= 0.0
            if ci != pi:
                t = ps / (ps - cs)
                nxt.append((prev[0] + (cur[0] - prev[0]) * t, prev[1] + (cur[1] - prev[1]) * t))
            if ci:
                nxt.append(cur)
        clipped = nxt
    return clipped


def polygon_iou(a: Sequence[Tuple[float, float]], b: Sequence[Tuple[float, float]]) -> float:
    aa, ab = polygon_area_abs(a), polygon_area_abs(b)
    if aa <= 0.0 or ab <= 0.0:
        return 0.0
    inter_poly = clip_convex_polygon(a, b)
    if len(inter_poly) < 3:
        return 0.0
    inter = polygon_area_abs(inter_poly)
    union = aa + ab - inter
    return inter / union if union > 0.0 else 0.0


def intersection_over_first(
    inner: Sequence[Tuple[float, float]], outer: Sequence[Tuple[float, float]]
) -> float:
    aa = polygon_area_abs(inner)
    if aa <= 0.0:
        return 0.0
    inter_poly = clip_convex_polygon(inner, outer)
    if len(inter_poly) < 3:
        return 0.0
    return polygon_area_abs(inter_poly) / aa


@dataclass
class QuadAssessment:
    issues: List[str]
    area_fraction: Optional[float] = None
    aspect: Optional[float] = None
    geometry_confidence: Optional[float] = None
    rejection: Optional[str] = None

    @property
    def acceptable(self) -> bool:
        return len(self.issues) == 0


def assess_quad(
    corners: Sequence[Tuple[float, float]], source_width: int, source_height: int
) -> QuadAssessment:
    """Bit-for-bit mirror of `assessQuad` in `lib/domain/quad_assessment.dart`."""
    if len(corners) != 4:
        return QuadAssessment(issues=["wrongPointCount"], rejection="wrongPointCount")
    for x, y in corners:
        if (
            not (math.isfinite(x) and math.isfinite(y))
            or x < -0.001
            or x > 1.001
            or y < -0.001
            or y > 1.001
        ):
            return QuadAssessment(issues=["outOfBounds"], rejection="outOfBounds")

    px = [x * (source_width - 1) for x, _ in corners]
    py = [y * (source_height - 1) for _, y in corners]
    twice_area = 0.0
    for i in range(4):
        j = (i + 1) % 4
        k = (i + 2) % 4
        cross = (px[j] - px[i]) * (py[k] - py[j]) - (py[j] - py[i]) * (px[k] - px[j])
        if cross <= 0.0:
            return QuadAssessment(issues=["notConvex"], rejection="notConvex")
        twice_area += px[i] * py[j] - px[j] * py[i]

    area = abs(twice_area) / 2.0
    frame = float(source_width - 1) * float(source_height - 1)
    area_frac = 0.0 if frame <= 0.0 else area / frame
    if area_frac < 0.02:
        return QuadAssessment(issues=["tooSmall"], rejection="tooSmall")

    def _dist_idx(a_i: int, b_i: int) -> float:
        return math.hypot(
            (corners[a_i][0] - corners[b_i][0]) * (source_width - 1),
            (corners[a_i][1] - corners[b_i][1]) * (source_height - 1),
        )

    top = _dist_idx(0, 1)
    bottom = _dist_idx(3, 2)
    left = _dist_idx(0, 3)
    right = _dist_idx(1, 2)
    edges = [top, bottom, left, right]
    if any(e < 4.0 for e in edges):
        return QuadAssessment(issues=["degenerateEdges"], rejection="degenerateEdges")

    h_ratio = max(top, bottom) / min(top, bottom)
    v_ratio = max(left, right) / min(left, right)
    if h_ratio > 2.5 or v_ratio > 2.5:
        return QuadAssessment(issues=["degenerateEdges"], rejection="degenerateEdges")

    width = 0.5 * (top + bottom)
    height = 0.5 * (left + right)
    aspect = max(width, height) / min(width, height)
    if aspect > 12.0:
        return QuadAssessment(issues=["implausibleAspect"], rejection="implausibleAspect")

    angle_score = 1.0
    for i in range(4):
        prev_i = (i + 3) % 4
        next_i = (i + 1) % 4
        v1x, v1y = px[prev_i] - px[i], py[prev_i] - py[i]
        v2x, v2y = px[next_i] - px[i], py[next_i] - py[i]
        n1 = math.hypot(v1x, v1y)
        n2 = math.hypot(v2x, v2y)
        cosine = max(-1.0, min(1.0, (v1x * v2x + v1y * v2y) / (n1 * n2)))
        angle = math.acos(cosine) * 180.0 / math.pi
        deviation = abs(angle - 90.0)
        angle_score = min(angle_score, max(0.0, min(1.0, 1.0 - deviation / 45.0)))

    edge_score = max(0.0, min(1.0, 1.0 - (max(h_ratio, v_ratio) - 1.0) / 1.5))
    area_score = max(0.0, min(1.0, area_frac / 0.15))
    confidence = max(
        0.0, min(1.0, 0.5 * angle_score + 0.3 * edge_score + 0.2 * area_score)
    )
    return QuadAssessment(
        issues=[],
        area_fraction=area_frac,
        aspect=aspect,
        geometry_confidence=confidence,
        rejection=None,
    )


@dataclass
class BoundaryProposalPy:
    producer: str  # 'wholeFrameDetector' | 'learnedModel' | 'segmenter' | 'manual'
    corners: Optional[List[Tuple[float, float]]] = None
    region: Optional[List[float]] = None
    imposed_aspect: Optional[float] = None
    model_confidence: Optional[float] = None
    min_auto_accept_confidence: Optional[float] = None
    touches_frame_edge: bool = False


@dataclass
class BoundaryDecisionPy:
    kind: str  # 'accepted' | 'needsReview' | 'rejected'
    proposal: BoundaryProposalPy
    reasons: List[str] = field(default_factory=list)
    has_usable_geometry: bool = False
    measured_aspect: Optional[float] = None


def verify_boundary(
    proposal: BoundaryProposalPy, source_width: int, source_height: int
) -> BoundaryDecisionPy:
    """Mirrors `verifyBoundary` in `lib/domain/boundary_decision.dart`."""
    if proposal.corners is None:
        return BoundaryDecisionPy(
            kind="needsReview", proposal=proposal, reasons=["noBoundary"]
        )
    if len(proposal.corners) != 4:
        return BoundaryDecisionPy(
            kind="rejected", proposal=proposal, reasons=["notABoundary"]
        )
    assess = assess_quad(proposal.corners, source_width, source_height)
    if not assess.acceptable:
        return BoundaryDecisionPy(
            kind="needsReview",
            proposal=proposal,
            reasons=["geometryRejected"],
            has_usable_geometry=False,
        )
    reasons: List[str] = []
    measured = assess.aspect or 1.0
    if proposal.imposed_aspect is not None and proposal.imposed_aspect > 0:
        ratio = (
            measured / proposal.imposed_aspect
            if measured >= proposal.imposed_aspect
            else proposal.imposed_aspect / measured
        )
        if ratio > MAX_ASPECT_CLAIM_RATIO:
            reasons.append("aspectMismatch")

    if proposal.region is not None and len(proposal.region) == 4:
        xs = [p[0] for p in proposal.corners]
        ys = [p[1] for p in proposal.corners]
        cx, cy = sum(xs) / 4.0, sum(ys) / 4.0
        r = proposal.region
        overlaps = max(xs) > r[0] and min(xs) < r[2] and max(ys) > r[1] and min(ys) < r[3]
        inside = r[0] <= cx <= r[2] and r[1] <= cy <= r[3]
        if not overlaps or not inside:
            reasons.append("quadOutsideRegion")

    learned_edge = (
        proposal.producer == "learnedModel"
        and proposal.region is None
        and any(
            x <= 0.016 or x >= 0.984 or y <= 0.016 or y >= 0.984
            for x, y in proposal.corners
        )
    )
    if proposal.touches_frame_edge or learned_edge:
        reasons.append("touchesFrameEdge")

    if proposal.model_confidence is not None and proposal.min_auto_accept_confidence is not None:
        if (
            not math.isfinite(proposal.model_confidence)
            or proposal.model_confidence < proposal.min_auto_accept_confidence
        ):
            reasons.append("lowModelConfidence")

    return BoundaryDecisionPy(
        kind="accepted" if len(reasons) == 0 else "needsReview",
        proposal=proposal,
        reasons=reasons,
        has_usable_geometry=True,
        measured_aspect=measured,
    )


# ---------------------------------------------------------------------------
# Exact Port of `lib/imaging/document_detector.dart`
# ---------------------------------------------------------------------------


def _dart_median(vals: Sequence[float]) -> float:
    s = sorted(vals)
    return float(s[len(s) // 2])


def _resize_box(
    rgb: np.ndarray,
    max_side: int,
    resample: int = Image.Resampling.BOX,
) -> np.ndarray:
    h, w = rgb.shape[:2]
    longest = max(w, h)
    if longest <= max_side:
        return rgb.astype(np.float32)
    scale = max_side / float(longest)
    nw = max(1, int(round(w * scale)))
    nh = max(1, int(round(h * scale)))
    pil = Image.fromarray(rgb.astype(np.uint8)).resize((nw, nh), resample)
    return np.asarray(pil, dtype=np.float32)


def _blur5(arr: np.ndarray) -> np.ndarray:
    """Separable `[1, 4, 6, 4, 1] / 16` blur with clamped borders."""
    p = np.pad(arr, ((0, 0), (2, 2), (0, 0)) if arr.ndim == 3 else ((0, 0), (2, 2)), mode="edge")
    if arr.ndim == 3:
        h_blur = (
            p[:, 0:-4, :]
            + 4.0 * p[:, 1:-3, :]
            + 6.0 * p[:, 2:-2, :]
            + 4.0 * p[:, 3:-1, :]
            + p[:, 4:, :]
        ) / 16.0
        p2 = np.pad(h_blur, ((2, 2), (0, 0), (0, 0)), mode="edge")
        return (
            p2[0:-4, :, :]
            + 4.0 * p2[1:-3, :, :]
            + 6.0 * p2[2:-2, :, :]
            + 4.0 * p2[3:-1, :, :]
            + p2[4:, :, :]
        ) / 16.0
    h_blur = (p[:, 0:-4] + 4.0 * p[:, 1:-3] + 6.0 * p[:, 2:-2] + 4.0 * p[:, 3:-1] + p[:, 4:]) / 16.0
    p2 = np.pad(h_blur, ((2, 2), (0, 0)), mode="edge")
    return (p2[0:-4, :] + 4.0 * p2[1:-3, :] + 6.0 * p2[2:-2, :] + 4.0 * p2[3:-1, :] + p2[4:, :]) / 16.0


@dataclass
class _FieldPy:
    width: int
    height: int
    rgb: np.ndarray  # float32 (H, W, 3)
    mag: np.ndarray  # float32 (H, W)
    nx: np.ndarray  # float32 (H, W)
    ny: np.ndarray  # float32 (H, W)

    @staticmethod
    def build(rgb: np.ndarray, smooth: bool) -> "_FieldPy":
        c = _blur5(rgb) if smooth else rgb
        h, w = c.shape[:2]
        p = np.pad(c, ((1, 1), (1, 1), (0, 0)), mode="edge")
        gx = (
            p[0:-2, 2:, :]
            - p[0:-2, 0:-2, :]
            + 2.0 * (p[1:-1, 2:, :] - p[1:-1, 0:-2, :])
            + p[2:, 2:, :]
            - p[2:, 0:-2, :]
        )
        gy = (
            p[2:, 0:-2, :]
            - p[0:-2, 0:-2, :]
            + 2.0 * (p[2:, 1:-1, :] - p[0:-2, 1:-1, :])
            + p[2:, 2:, :]
            - p[0:-2, 2:, :]
        )
        gxx = np.sum(gx * gx, axis=2)
        gyy = np.sum(gy * gy, axis=2)
        gxy = np.sum(gx * gy, axis=2)
        trace = gxx + gyy
        det = np.maximum(0.0, (gxx - gyy) ** 2 + 4.0 * gxy * gxy)
        root = np.sqrt(det)
        mag = np.sqrt(0.5 * (trace + root) / 3.0) / 4.0
        angle = 0.5 * np.arctan2(2.0 * gxy, gxx - gyy)
        return _FieldPy(
            width=w,
            height=h,
            rgb=c.astype(np.float32),
            mag=mag.astype(np.float32),
            nx=np.cos(angle).astype(np.float32),
            ny=np.sin(angle).astype(np.float32),
        )

    def aligned(self, x: float, y: float, ex: float, ey: float) -> float:
        xi, yi = int(round(x)), int(round(y))
        if xi < 0 or yi < 0 or xi >= self.width or yi >= self.height:
            return 0.0
        align = abs(float(self.nx[yi, xi]) * ex + float(self.ny[yi, xi]) * ey)
        return float(self.mag[yi, xi]) * align * align


def _otsu256(values: np.ndarray, max_val: float, bins: int = 256) -> float:
    top = max_val + 1e-9
    idx = np.minimum(bins - 1, np.floor(values.ravel() / top * bins).astype(np.int32))
    hist = np.bincount(idx, minlength=bins).astype(np.float64)
    total = float(values.size)
    sum_all = float(np.sum(np.arange(bins, dtype=np.float64) * hist))
    wb = 0.0
    sb = 0.0
    best = 0.0
    threshold = 0
    for i in range(bins):
        wb += hist[i]
        if wb == 0.0:
            continue
        wf = total - wb
        if wf == 0.0:
            break
        sb += i * hist[i]
        mb, mf = sb / wb, (sum_all - sb) / wf
        between = wb * wf * (mb - mf) ** 2
        if between > best:
            best = between
            threshold = i
    return (threshold + 1) * top / bins


def _morph(mask: np.ndarray, r: int, dilate: bool) -> np.ndarray:
    if r <= 0:
        return mask.copy()
    outside = 0 if dilate else 1
    src = mask
    for horiz in (True, False):
        h, w = src.shape
        pad = ((0, 0), (r, r)) if horiz else ((r, r), (0, 0))
        padded = np.pad(src, pad, mode="constant", constant_values=outside)
        acc = padded[:, 0:w].copy() if horiz else padded[0:h, :].copy()
        for k in range(1, 2 * r + 1):
            sl = padded[:, k : k + w] if horiz else padded[k : k + h, :]
            acc = np.maximum(acc, sl) if dilate else np.minimum(acc, sl)
        src = acc
    return src


try:
    from scipy.ndimage import binary_fill_holes as _scipy_fill_holes
    from scipy.ndimage import label as _scipy_label4
except ImportError:
    _scipy_fill_holes = None
    _scipy_label4 = None


def _fill_holes(mask: np.ndarray) -> np.ndarray:
    if _scipy_fill_holes is not None:
        return _scipy_fill_holes(mask.astype(bool)).astype(np.uint8)
    h, w = mask.shape
    reach = np.zeros((h, w), dtype=np.uint8)
    stack: List[Tuple[int, int]] = []
    for x in range(w):
        if mask[0, x] == 0 and reach[0, x] == 0:
            reach[0, x] = 1
            stack.append((0, x))
        if mask[h - 1, x] == 0 and reach[h - 1, x] == 0:
            reach[h - 1, x] = 1
            stack.append((h - 1, x))
    for y in range(h):
        if mask[y, 0] == 0 and reach[y, 0] == 0:
            reach[y, 0] = 1
            stack.append((y, 0))
        if mask[y, w - 1] == 0 and reach[y, w - 1] == 0:
            reach[y, w - 1] = 1
            stack.append((y, w - 1))
    while stack:
        cy, cx = stack.pop()
        if cx > 0 and mask[cy, cx - 1] == 0 and reach[cy, cx - 1] == 0:
            reach[cy, cx - 1] = 1
            stack.append((cy, cx - 1))
        if cx < w - 1 and mask[cy, cx + 1] == 0 and reach[cy, cx + 1] == 0:
            reach[cy, cx + 1] = 1
            stack.append((cy, cx + 1))
        if cy > 0 and mask[cy - 1, cx] == 0 and reach[cy - 1, cx] == 0:
            reach[cy - 1, cx] = 1
            stack.append((cy - 1, cx))
        if cy < h - 1 and mask[cy + 1, cx] == 0 and reach[cy + 1, cx] == 0:
            reach[cy + 1, cx] = 1
            stack.append((cy + 1, cx))
    return (reach == 0).astype(np.uint8)


def _components4(mask: np.ndarray) -> List[List[int]]:
    if _scipy_label4 is not None:
        labeled, num = _scipy_label4(
            mask != 0,
            structure=np.array([[0, 1, 0], [1, 1, 1], [0, 1, 0]], dtype=np.int32),
        )
        if num == 0:
            return []
        flat_lbl = labeled.ravel()
        nz = np.flatnonzero(flat_lbl)
        order = np.argsort(flat_lbl[nz], kind="mergesort")
        sorted_idx = nz[order]
        counts = np.bincount(flat_lbl[sorted_idx], minlength=num + 1)[1:]
        splits = np.cumsum(counts)[:-1]
        return [arr.tolist() for arr in np.split(sorted_idx, splits) if arr.size > 0]
    h, w = mask.shape
    flat = mask.ravel()
    labels = np.full(flat.size, -1, dtype=np.int32)
    out: List[List[int]] = []
    for s in range(flat.size):
        if flat[s] == 0 or labels[s] >= 0:
            continue
        cid = len(out)
        pts = [s]
        labels[s] = cid
        head = 0
        while head < len(pts):
            idx = pts[head]
            head += 1
            x, y = idx % w, idx // w
            if x > 0 and flat[idx - 1] != 0 and labels[idx - 1] < 0:
                labels[idx - 1] = cid
                pts.append(idx - 1)
            if x < w - 1 and flat[idx + 1] != 0 and labels[idx + 1] < 0:
                labels[idx + 1] = cid
                pts.append(idx + 1)
            if y > 0 and flat[idx - w] != 0 and labels[idx - w] < 0:
                labels[idx - w] = cid
                pts.append(idx - w)
            if y < h - 1 and flat[idx + w] != 0 and labels[idx + w] == -1:
                labels[idx + w] = cid
                pts.append(idx + w)
        out.append(pts)
    return out


def detect_letterbox_viewport(rgb: np.ndarray) -> Tuple[int, int, int, int]:
    """Mirrors `_detectLetterboxViewport` in `lib/imaging/document_detector.dart`."""
    h, w = rgb.shape[:2]
    if w < 40 or h < 40:
        return (0, 0, w, h)
    arr = rgb.astype(np.float64)

    def scan_rows(start: int, step: int) -> int:
        ref = None
        count = 0
        y = start
        while 0 <= y < h:
            row = arr[y]
            mean = row.mean(axis=0)
            if ref is None:
                ref = mean
            var = np.maximum(0.0, (row * row).mean(axis=0) - mean * mean)
            max_std = float(np.sqrt(np.max(var)))
            if max_std <= 5.0 and np.all(np.abs(mean - ref) <= 3.0):
                count += 1
                y += step
            else:
                break
        if count < 6 or ref is None:
            return 0
        by = start + count * step
        if by < 0 or by >= h:
            return 0
        diff2 = np.sum((arr[by] - ref[None, :]) ** 2, axis=1)
        return count if int(np.sum(diff2 >= 324.0)) >= 0.92 * w else 0

    def scan_cols(start: int, step: int) -> int:
        ref = None
        count = 0
        x = start
        while 0 <= x < w:
            col = arr[:, x, :]
            mean = col.mean(axis=0)
            if ref is None:
                ref = mean
            var = np.maximum(0.0, (col * col).mean(axis=0) - mean * mean)
            max_std = float(np.sqrt(np.max(var)))
            if max_std <= 5.0 and np.all(np.abs(mean - ref) <= 3.0):
                count += 1
                x += step
            else:
                break
        if count < 6 or ref is None:
            return 0
        bx = start + count * step
        if bx < 0 or bx >= w:
            return 0
        diff2 = np.sum((arr[:, bx, :] - ref[None, :]) ** 2, axis=1)
        return count if int(np.sum(diff2 >= 324.0)) >= 0.92 * h else 0

    top = scan_rows(0, 1)
    bottom = scan_rows(h - 1, -1)
    left = scan_cols(0, 1)
    right = scan_cols(w - 1, -1)
    vw = w - left - right
    vh = h - top - bottom
    if vw < math.floor(w * 0.6) or vh < math.floor(h * 0.6) or vw < 20 or vh < 20:
        return (0, 0, w, h)
    return (left, top, vw, vh)


def order_quad_dart(q: Sequence[Tuple[float, float]]) -> List[Tuple[float, float]]:
    """Mirrors `_orderQuad` in `lib/imaging/document_detector.dart`."""
    cx = sum(p[0] for p in q) / 4.0
    cy = sum(p[1] for p in q) / 4.0
    pts = sorted(q, key=lambda p: math.atan2(p[1] - cy, p[0] - cx))
    area2 = 0.0
    for i in range(4):
        a, b = pts[i], pts[(i + 1) % 4]
        area2 += a[0] * b[1] - b[0] * a[1]
    if area2 < 0.0:
        pts = list(reversed(pts))
    lengths = [math.hypot(pts[(i + 1) % 4][0] - pts[i][0], pts[(i + 1) % 4][1] - pts[i][1]) for i in range(4)]
    max_len = max(1e-6, max(lengths))
    start = 0
    best_score = -1e18
    for i in range(4):
        a, b = pts[i], pts[(i + 1) % 4]
        ln = lengths[i]
        if ln <= 0.0:
            continue
        dx = (b[0] - a[0]) / ln
        if dx <= 0.0:
            continue
        sc = dx + 1.15 * (ln / max_len)
        if sc > best_score:
            best_score = sc
            start = i
    return [pts[(start + i) % 4] for i in range(4)]


def _on_border(a: Tuple[float, float], b: Tuple[float, float], w: int, h: int, m: float) -> bool:
    return (
        (a[0] <= m and b[0] <= m)
        or (a[1] <= m and b[1] <= m)
        or (a[0] >= w - 1 - m and b[0] >= w - 1 - m)
        or (a[1] >= h - 1 - m and b[1] >= h - 1 - m)
    )


def _valid_quad(q: Sequence[Tuple[float, float]], w: int, h: int, min_area: float) -> bool:
    for i in range(4):
        if _cross2(q[i][0], q[i][1], q[(i + 1) % 4][0], q[(i + 1) % 4][1], q[(i + 2) % 4][0], q[(i + 2) % 4][1]) <= 0.0:
            return False
        a, b, c = q[(i + 3) % 4], q[i], q[(i + 1) % 4]
        v1x, v1y = a[0] - b[0], a[1] - b[1]
        v2x, v2y = c[0] - b[0], c[1] - b[1]
        ln = math.hypot(v1x, v1y) * math.hypot(v2x, v2y)
        if ln == 0.0:
            return False
        ang = math.degrees(math.acos(max(-1.0, min(1.0, (v1x * v2x + v1y * v2y) / ln))))
        if ang < 45.0 or ang > 135.0:
            return False
    m = 0.04 * max(w, h)
    for x, y in q:
        if x < -m or y < -m or x > w - 1 + m or y > h - 1 + m:
            return False
    return polygon_area_abs(q) >= min_area * w * h


def _angle_diff(a: float, b: float) -> float:
    d = abs(a - b) % 180.0
    return 180.0 - d if d > 90.0 else d


def _line_intersect(
    l1: Tuple[Tuple[float, float], Tuple[float, float]],
    l2: Tuple[Tuple[float, float], Tuple[float, float]],
) -> Optional[Tuple[float, float]]:
    (x1, y1), (x2, y2) = l1
    (x3, y3), (x4, y4) = l2
    d = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
    if abs(d) < 1e-9:
        return None
    a = x1 * y2 - y1 * x2
    b = x3 * y4 - y3 * x4
    return ((a * (x3 - x4) - (x1 - x2) * b) / d, (a * (y3 - y4) - (y1 - y2) * b) / d)


def _convex_hull(points: Sequence[Tuple[float, float]]) -> List[Tuple[float, float]]:
    pts = sorted(points)
    if len(pts) < 3:
        return list(pts)
    lower: List[Tuple[float, float]] = []
    for p in pts:
        while len(lower) >= 2 and _cross2(lower[-2][0], lower[-2][1], lower[-1][0], lower[-1][1], p[0], p[1]) <= 0.0:
            lower.pop()
        lower.append(p)
    upper: List[Tuple[float, float]] = []
    for p in reversed(pts):
        while len(upper) >= 2 and _cross2(upper[-2][0], upper[-2][1], upper[-1][0], upper[-1][1], p[0], p[1]) <= 0.0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def _enclosing_quad(hull: Sequence[Tuple[float, float]]) -> List[Tuple[float, float]]:
    p = list(hull)
    while len(p) > 4:
        n = len(p)
        best_idx = None
        best_pt = None
        best_add = float("inf")
        for i in range(n):
            a, b, c, d = p[(i - 1) % n], p[i], p[(i + 1) % n], p[(i + 2) % n]
            x = _line_intersect((a, b), (c, d))
            if x is None:
                continue
            if (x[0] - b[0]) * (b[0] - a[0]) + (x[1] - b[1]) * (b[1] - a[1]) < -1e-9:
                continue
            if (x[0] - c[0]) * (c[0] - d[0]) + (x[1] - c[1]) * (c[1] - d[1]) < -1e-9:
                continue
            added = abs(_cross2(b[0], b[1], x[0], x[1], c[0], c[1])) / 2.0
            if added < best_add:
                best_add = added
                best_idx = i
                best_pt = x
        if best_idx is None:
            rem = min(
                range(n),
                key=lambda i: abs(_cross2(p[(i - 1) % n][0], p[(i - 1) % n][1], p[i][0], p[i][1], p[(i + 1) % n][0], p[(i + 1) % n][1])),
            )
            p.pop(rem)
            continue
        assert best_pt is not None
        p[best_idx] = best_pt
        p.pop((best_idx + 1) % n)
    return p


def _fit_line(pts: List[Tuple[float, float]]) -> Tuple[Tuple[float, float], Tuple[float, float]]:
    points = pts
    cx = cy = 0.0
    dx, dy = 1.0, 0.0
    for _ in range(3):
        mx = sum(p[0] for p in points) / len(points)
        my = sum(p[1] for p in points) / len(points)
        sxx = sum((p[0] - mx) ** 2 for p in points)
        syy = sum((p[1] - my) ** 2 for p in points)
        sxy = sum((p[0] - mx) * (p[1] - my) for p in points)
        ang = 0.5 * math.atan2(2.0 * sxy, sxx - syy)
        cx, cy = mx, my
        dx, dy = math.cos(ang), math.sin(ang)
        residuals = [abs((p[0] - mx) * (-dy) + (p[1] - my) * dx) for p in points]
        limit = max(1.0, 2.5 * _dart_median(residuals))
        kept = [points[i] for i in range(len(points)) if residuals[i] <= limit]
        if len(kept) == len(points) or len(kept) < 8:
            break
        points = kept
    return ((cx, cy), (cx + dx, cy + dy))


def _colour_spread(samples: List[Tuple[float, float, float]]) -> float:
    total = 0.0
    n = len(samples)
    for ch in range(3):
        vals = [s[ch] for s in samples]
        m = sum(vals) / n
        total += math.sqrt(sum((x - m) ** 2 for x in vals) / n)
    return total / 3.0


def _score_quad(f: _FieldPy, q: Sequence[Tuple[float, float]], low: float) -> Optional[Dict[str, float]]:
    w, h = f.width, f.height
    supports: List[float] = []
    strengths: List[float] = []
    contrasts: List[float] = []
    textures: List[float] = []
    c = f.rgb
    unverified_border = 0
    for i in range(4):
        a, b = q[i], q[(i + 1) % 4]
        length = math.hypot(b[0] - a[0], b[1] - a[1])
        if length < 4.0:
            return None
        tx, ty = (b[0] - a[0]) / length, (b[1] - a[1]) / length
        nx, ny = ty, -tx
        is_border = _on_border(a, b, w, h, 2.5)
        n = int(min(80, max(12, int(length / 3.0))))
        ts = 0.1 + 0.8 * np.arange(n, dtype=np.float64) / (n - 1)
        xs = a[0] + (b[0] - a[0]) * ts
        ys = a[1] + (b[1] - a[1]) * ts
        offs = np.array([-2.0, -1.0, 0.0, 1.0, 2.0], dtype=np.float64)[:, None]
        oxs = np.rint(xs[None, :] + nx * offs).astype(np.int32)
        oys = np.rint(ys[None, :] + ny * offs).astype(np.int32)
        valid_o = (oxs >= 0) & (oxs < w) & (oys >= 0) & (oys < h)
        oxs_c = np.clip(oxs, 0, w - 1)
        oys_c = np.clip(oys, 0, h - 1)
        align_c = np.abs(f.nx[oys_c, oxs_c] * nx + f.ny[oys_c, oxs_c] * ny)
        vals = np.where(valid_o, f.mag[oys_c, oxs_c] * align_c * align_c, 0.0)
        bests = np.max(vals, axis=0)
        hits = int(np.sum(bests >= low))
        sup_val = hits / float(n)
        str_val = min(1.0, _dart_median(bests.tolist()) / (2.5 * low))
        if is_border and sup_val < 0.65:
            unverified_border += 1
        supports.append(max(0.55, sup_val) if is_border else sup_val)
        strengths.append(max(0.5, str_val) if is_border else str_val)

        xis = np.rint(xs - nx * 4.0).astype(np.int32)
        yis = np.rint(ys - ny * 4.0).astype(np.int32)
        xos = np.rint(xs + nx * 4.0).astype(np.int32)
        yos = np.rint(ys + ny * 4.0).astype(np.int32)
        in_io = (xis >= 0) & (xis < w) & (yis >= 0) & (yis < h) & (xos >= 0) & (xos < w) & (yos >= 0) & (yos < h)
        cnt_io = int(np.sum(in_io))
        if cnt_io > 0:
            pins = c[yis[in_io], xis[in_io]].astype(np.float64)
            pouts = c[yos[in_io], xos[in_io]].astype(np.float64)
            cs_arr = np.sqrt(np.sum((pins - pouts) ** 2, axis=1))
            contrasts.append(_dart_median(cs_arr.tolist()))
            if cnt_io >= 6:
                sp_in = float(np.mean(np.std(pins, axis=0)))
                sp_out = float(np.mean(np.std(pouts, axis=0)))
                textures.append(min(sp_in, sp_out))

    if unverified_border > 2:
        return None

    saturated = [min(1.0, s / 0.9) for s in supports]
    mean_sup = sum(supports) / 4.0
    min_sup = min(supports)
    mean_sat = sum(saturated) / 4.0
    min_sat = min(saturated)
    contrast = min(1.0, (sum(contrasts) / len(contrasts) if contrasts else 0.0) / 40.0)
    area = polygon_area_abs(q) / float(w * h)
    strength = sum(strengths) / 4.0
    textures.sort()
    texture = textures[1] if len(textures) >= 2 else 0.0
    penalty = min(1.0, max(0.0, (texture - 15.0) / 30.0))
    total = (
        0.4 * mean_sat
        + 0.2 * min_sat
        + 0.1 * contrast
        + 0.15 * strength
        + 0.1 * math.sqrt(max(0.0, area))
        - 0.3 * penalty
    )
    return {"total": total, "mean": mean_sup, "min": min_sup, "area": area, "texture": texture}


def _side_sharpness(f: _FieldPy, q: Sequence[Tuple[float, float]], k: float) -> List[float]:
    r = max(1, int(round(k)))
    vals: List[float] = []
    for i in range(4):
        a, b = q[i], q[(i + 1) % 4]
        if _on_border(a, b, f.width, f.height, 2.5 * k):
            continue
        length = math.hypot(b[0] - a[0], b[1] - a[1])
        nx, ny = (b[1] - a[1]) / length, -(b[0] - a[0]) / length
        side: List[float] = []
        for j in range(24):
            t = 0.1 + 0.8 * j / 23.0
            x, y = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
            best = 0.0
            for o in range(-r, r + 1):
                val = f.aligned(x + nx * o, y + ny * o, nx, ny)
                if val > best:
                    best = val
            side.append(best)
        vals.append(_dart_median(side))
    return vals


def _content_bonus(f: _FieldPy, q: Sequence[Tuple[float, float]], frame_p75: float) -> float:
    """Statement-for-statement port of `_contentBonus` in `document_detector.dart`."""
    if frame_p75 <= 1e-6:
        return 0.0
    w, h = f.width, f.height
    min_x = max(0, min(w - 1, min(int(math.floor(p[0])) for p in q)))
    max_x = max(0, min(w - 1, max(int(math.ceil(p[0])) for p in q)))
    min_y = max(0, min(h - 1, min(int(math.floor(p[1])) for p in q)))
    max_y = max(0, min(h - 1, max(int(math.ceil(p[1])) for p in q)))
    step_x = max(1, int(math.floor((max_x - min_x) / 24.0)))
    step_y = max(1, int(math.floor((max_y - min_y) / 24.0)))
    s = 0.0
    cnt = 0
    for y in range(min_y, max_y + 1, step_y):
        for x in range(min_x, max_x + 1, step_x):
            fx, fy = float(x), float(y)
            inside = True
            for e in range(4):
                if _cross2(q[e][0], q[e][1], q[(e + 1) % 4][0], q[(e + 1) % 4][1], fx, fy) <= 0.0:
                    inside = False
                    break
            if inside:
                s += float(f.mag[y, x])
                cnt += 1
    if cnt < 8:
        return 0.0
    return min(1.0, max(0.0, (s / cnt) / frame_p75))


def _refine_quad(
    f: _FieldPy,
    q: Sequence[Tuple[float, float]],
    low: float,
    radius: int,
    border_tol: float,
) -> Optional[List[Tuple[float, float]]]:
    """Statement-for-statement port of `_refine` in `document_detector.dart`."""
    lines: List[Tuple[Tuple[float, float], Tuple[float, float]]] = []
    for i in range(4):
        a, b = q[i], q[(i + 1) % 4]
        length = math.hypot(b[0] - a[0], b[1] - a[1])
        if length < 1.0:
            return None
        nx, ny = (b[1] - a[1]) / length, -(b[0] - a[0]) / length
        pts: List[Tuple[float, float]] = []
        if not _on_border(a, b, f.width, f.height, border_tol):
            n = int(min(120, max(16, int(length / 2.0))))
            values = [0.0] * (2 * radius + 1)
            for k in range(n):
                t = 0.08 + 0.84 * k / (n - 1)
                x = a[0] + (b[0] - a[0]) * t
                y = a[1] + (b[1] - a[1]) * t
                j_best = 0
                w_best = -1.0
                for o in range(-radius, radius + 1):
                    v = f.aligned(x + nx * o, y + ny * o, nx, ny)
                    values[o + radius] = v
                    weighted = v * (1.0 - 0.5 * ((o / float(radius)) ** 2))
                    if weighted > w_best:
                        w_best = weighted
                        j_best = o + radius
                if values[j_best] < low:
                    continue
                offset = float(j_best - radius)
                if 0 < j_best < len(values) - 1:
                    den = values[j_best - 1] - 2.0 * values[j_best] + values[j_best + 1]
                    if den < 0.0:
                        offset += 0.5 * (values[j_best - 1] - values[j_best + 1]) / den
                pts.append((x + nx * offset, y + ny * offset))
        lines.append(_fit_line(pts) if len(pts) >= 8 else (a, b))

    out: List[Tuple[float, float]] = []
    for i in range(4):
        x = _line_intersect(lines[(i + 3) % 4], lines[i])
        if x is None:
            return None
        out.append(x)
    return out


def _run_detector_pass(
    cf: _FieldPy,
    ff: _FieldPy,
    scale_k: float,
    sensitivity: float,
    need_mean: float,
    need_min: float,
) -> Optional[Tuple[List[Tuple[float, float]], float]]:
    """Statement-for-statement port of `_Detector.runScored` in `document_detector.dart`."""
    w, h = cf.width, cf.height
    if min(w, h) < 20:
        return None
    n = w * h
    sorted_mag = np.sort(cf.mag.ravel())
    p75 = float(sorted_mag[int(round((n - 1) * 0.75))])
    p90 = float(sorted_mag[int(round((n - 1) * 0.90))])
    high = max(12.0, p90)
    low = max(3.0, 0.45 * high * sensitivity)

    proposals: List[List[Tuple[float, float]]] = []

    # 1. Exact k-means (k=3) border segmentation + dual threshold (`_segmentationCandidates`)
    c = cf.rgb
    band = max(2, int(round(min(w, h) * 0.02)))
    border_indices: List[int] = []
    for y in range(h):
        for x in range(w):
            if y < band or y >= h - band or x < band or x >= w - band:
                border_indices.append(y * w + x)
    b_arr = np.asarray(border_indices, dtype=np.int32)
    flat_rgb = c.reshape((n, 3))
    b_rgb = flat_rgb[b_arr]
    centres = np.array(
        [b_rgb[0], b_rgb[len(border_indices) // 2], b_rgb[-1]],
        dtype=np.float64,
    )
    labels = np.zeros(len(border_indices), dtype=np.int32)
    for _ in range(8):
        d2 = np.sum((b_rgb[:, None, :] - centres[None, :, :]) ** 2, axis=2)
        labels = np.argmin(d2, axis=1)
        for k_i in range(3):
            mk = labels == k_i
            if np.any(mk):
                centres[k_i] = np.mean(b_rgb[mk], axis=0)
    kept = [centres[k_i] for k_i in range(3) if int(np.sum(labels == k_i)) >= 0.1 * len(border_indices)]
    kept_arr = np.asarray(kept, dtype=np.float64)
    dist = np.sqrt(np.min(np.sum((flat_rgb[:, None, :] - kept_arr[None, :, :]) ** 2, axis=2), axis=1)).astype(np.float32)
    max_d = float(np.max(dist))
    otsu_thr = max(18.0, _otsu256(dist, max_d))
    b_dist_sorted = np.sort(dist[b_arr])
    border_p90 = float(b_dist_sorted[int(round((len(border_indices) - 1) * 0.9))])
    thresholds = [otsu_thr]
    if border_p90 <= 32.0:
        thresholds.append(max(18.0, 2.5 * border_p90))

    for thr in thresholds:
        mask = (dist > thr).astype(np.uint8).reshape((h, w))
        mask = _morph(_morph(mask, 2, True), 2, False)
        mask = _fill_holes(mask)
        mask = _morph(_morph(mask, 2, False), 2, True)
        comps = sorted(_components4(mask), key=len, reverse=True)
        for comp in comps[:3]:
            if len(comp) < 0.03 * n:
                break
            if len(comp) > 0.995 * n:
                continue
            arr_c = np.asarray(comp, dtype=np.int32)
            xs_c, ys_c = arr_c % w, arr_c // w
            left_map: Dict[int, int] = {}
            right_map: Dict[int, int] = {}
            for i_pt in range(arr_c.size):
                xv, yv = int(xs_c[i_pt]), int(ys_c[i_pt])
                if yv not in left_map or xv < left_map[yv]:
                    left_map[yv] = xv
                if yv not in right_map or xv > right_map[yv]:
                    right_map[yv] = xv
            pts_lr = []
            for yv in left_map:
                pts_lr.append((float(left_map[yv]), float(yv)))
                pts_lr.append((float(right_map[yv]), float(yv)))
            hull = _convex_hull(pts_lr)
            if len(hull) < 4:
                continue
            quad = _enclosing_quad(hull)
            if len(quad) != 4:
                continue
            ordered = order_quad_dart(quad)
            if _valid_quad(ordered, w, h, 0.03):
                proposals.append(ordered)

    # 2. Exact NMS + step-edge Hough peaks + frame border completion (`_houghCandidates`)
    diag = int(math.ceil(math.hypot(w, h)))
    rho_bins = 2 * diag + 1
    acc = np.zeros(180 * rho_bins, dtype=np.float64)
    cosv = np.cos(np.arange(180, dtype=np.float64) * math.pi / 180.0)
    sinv = np.sin(np.arange(180, dtype=np.float64) * math.pi / 180.0)

    ys_m, xs_m = np.nonzero(cf.mag[1 : h - 1, 1 : w - 1] >= low)
    ys_m = ys_m + 1
    xs_m = xs_m + 1
    if xs_m.size > 0:
        m_vals = cf.mag[ys_m, xs_m].astype(np.float64)
        nx_vals = cf.nx[ys_m, xs_m].astype(np.float64)
        ny_vals = cf.ny[ys_m, xs_m].astype(np.float64)
        dxs = np.rint(nx_vals).astype(np.int32)
        dys = np.rint(ny_vals).astype(np.int32)
        nms_ok = (m_vals >= cf.mag[ys_m + dys, xs_m + dxs]) & (m_vals >= cf.mag[ys_m - dys, xs_m - dxs])
        xs_m, ys_m, m_vals, nx_vals, ny_vals = xs_m[nms_ok], ys_m[nms_ok], m_vals[nms_ok], nx_vals[nms_ok], ny_vals[nms_ok]
        if xs_m.size > 0:
            xas = np.rint(xs_m + nx_vals * 3.0).astype(np.int32)
            yas = np.rint(ys_m + ny_vals * 3.0).astype(np.int32)
            xbs = np.rint(xs_m - nx_vals * 3.0).astype(np.int32)
            ybs = np.rint(ys_m - ny_vals * 3.0).astype(np.int32)
            in_b = (xas >= 0) & (xas < w) & (yas >= 0) & (yas < h) & (xbs >= 0) & (xbs < w) & (ybs >= 0) & (ybs < h)
            step_ok = np.ones(xs_m.size, dtype=bool)
            if np.any(in_b):
                diff_rgb = c[yas[in_b], xas[in_b]] - c[ybs[in_b], xbs[in_b]]
                step_rgb = np.sqrt(np.sum(diff_rgb * diff_rgb, axis=1))
                step_ok[in_b] = step_rgb >= np.maximum(12.0, 1.2 * m_vals[in_b])
            xs_v, ys_v = xs_m[step_ok].astype(np.float64), ys_m[step_ok].astype(np.float64)
            th_deg = np.rint(np.arctan2(ny_vals[step_ok], nx_vals[step_ok]) * 180.0 / math.pi).astype(np.int32) % 180
            for dt in range(-5, 6):
                tt = (th_deg + dt) % 180
                r_bin = np.rint(xs_v * cosv[tt] + ys_v * sinv[tt]).astype(np.int32) + diag
                np.add.at(acc, tt * rho_bins + r_bin, 1.0)

    min_votes = max(18.0, 0.065 * min(w, h))
    peaks: List[Tuple[int, float]] = []
    guard = 0
    while len(peaks) < 20 and guard < 80:
        guard += 1
        best_idx = int(np.argmax(acc))
        best_val = float(acc[best_idx])
        if best_val < min_votes:
            break
        t_pk, r_pk = best_idx // rho_bins, best_idx % rho_bins
        for dt in range(-6, 7):
            raw_t = t_pk + dt
            tt = raw_t % 180
            rr = r_pk if (0 <= raw_t < 180) else (2 * diag - r_pk)
            k_lo = max(0, rr - 8)
            k_hi = min(rho_bins, rr + 9)
            acc[tt * rho_bins + k_lo : tt * rho_bins + k_hi] = 0.0
        same_ori = sum(1 for p in peaks if _angle_diff(p[0], t_pk) <= 14.0)
        if same_ori < 6:
            peaks.append((t_pk, float(r_pk - diag)))

    if len(peaks) >= 3:
        for bt, brho in ((90, 0.0), (90, float(h - 1)), (0, 0.0), (0, float(w - 1))):
            if not any(_angle_diff(p[0], bt) <= 8.0 and abs(p[1] - brho) <= 6.0 for p in peaks):
                peaks.append((bt, brho))

    cx_f, cy_f = (w - 1) / 2.0, (h - 1) / 2.0
    pk_info = [
        (
            pk[0],
            pk[1],
            math.cos(pk[0] * math.pi / 180.0),
            math.sin(pk[0] * math.pi / 180.0),
        )
        for pk in peaks
    ]
    pairs: List[Tuple[int, int]] = []
    for i in range(len(pk_info)):
        for j in range(i + 1, len(pk_info)):
            a, b = pk_info[i], pk_info[j]
            if _angle_diff(a[0], b[0]) > 25.0:
                continue
            sa = cx_f * a[2] + cy_f * a[3] - a[1]
            sb = cx_f * b[2] + cy_f * b[3] - b[1]
            same_dir = (a[2] * b[2] + a[3] * b[3]) > 0.0
            gap = abs(sa - sb) if same_dir else abs(sa + sb)
            if gap < 0.1 * min(w, h):
                continue
            pairs.append((i, j))

    def pk_line(p_item: Tuple[int, float, float, float]) -> Tuple[Tuple[float, float], Tuple[float, float]]:
        x0, y0 = p_item[2] * p_item[1], p_item[3] * p_item[1]
        return ((x0, y0), (x0 - p_item[3] * 100.0, y0 + p_item[2] * 100.0))

    pk_lines = [pk_line(p) for p in pk_info]
    for p_idx in range(len(pairs)):
        a1, a2 = pairs[p_idx]
        for q_idx in range(p_idx + 1, len(pairs)):
            b1, b2 = pairs[q_idx]
            if len({a1, a2, b1, b2}) < 4:
                continue
            if _angle_diff(pk_info[a1][0], pk_info[b1][0]) < 55.0:
                continue
            seq = [pk_lines[a1], pk_lines[b1], pk_lines[a2], pk_lines[b2]]
            corners = []
            for k_c in range(4):
                inter = _line_intersect(seq[k_c], seq[(k_c + 1) % 4])
                if inter is None:
                    break
                corners.append(inter)
            if len(corners) != 4:
                continue
            ordered = order_quad_dart(corners)
            if _valid_quad(ordered, w, h, 0.04):
                proposals.append(ordered)

    # 3. Score + shortlist fine-vs-coarse sharpness re-ranking + 2-pass subpixel refinement
    scored_list: List[Tuple[List[Tuple[float, float]], Dict[str, float]]] = []
    for q in proposals:
        sc = _score_quad(cf, q, low)
        if sc is not None and sc["texture"] < 30.0 and sc["area"] < 0.985:
            cb = _content_bonus(cf, q, p75)
            scored_list.append(
                (
                    q,
                    {
                        "total": sc["total"] + 0.06 * cb,
                        "mean": sc["mean"],
                        "min": sc["min"],
                        "area": sc["area"],
                        "texture": sc["texture"],
                    },
                )
            )
    if not scored_list:
        return None
    scored_list.sort(key=lambda it: it[1]["total"], reverse=True)
    best_s = scored_list[0][1]
    if best_s["mean"] < need_mean or best_s["min"] < need_min:
        return None

    shortlist: List[Tuple[List[Tuple[float, float]], Dict[str, float]]] = []
    for cq, cs in scored_list:
        if cs["total"] < best_s["total"] - 0.05 or len(shortlist) >= 12:
            break
        if cs["mean"] < need_mean or cs["min"] < need_min:
            continue
        dup = any(
            all(math.hypot(oq[k_d][0] - cq[k_d][0], oq[k_d][1] - cq[k_d][1]) < 1.5 for k_d in range(4))
            for oq, _ in shortlist
        )
        if not dup:
            shortlist.append((cq, cs))

    pick_q, _ = shortlist[0]
    pick_val = -1e18
    for cq, cs in shortlist:
        scaled = [(p[0] * scale_k, p[1] * scale_k) for p in cq]
        fine_vals = _side_sharpness(ff, scaled, scale_k)
        coarse_vals = _side_sharpness(cf, cq, 1.0)
        fm = sum(fine_vals) / len(fine_vals) if fine_vals else 0.0
        cm = sum(coarse_vals) / len(coarse_vals) if coarse_vals else 0.0
        sharpness = min(1.0, fm / cm) if cm > 0.0 else 0.0
        val = cs["total"] + 0.2 * sharpness
        if val > pick_val:
            pick_val = val
            pick_q = cq

    q_cur = [(p[0] * scale_k, p[1] * scale_k) for p in pick_q]
    radius = max(3, int(round(3.0 * scale_k)))
    for _ in range(2):
        refined = _refine_quad(ff, q_cur, low * 0.5, radius, 2.5 * scale_k)
        if refined is None:
            break
        ordered_r = order_quad_dart(refined)
        if not _valid_quad(ordered_r, ff.width, ff.height, 0.03):
            break
        q_cur = refined
    return (order_quad_dart(q_cur), pick_val)


@dataclass
class ScoredQuadPy:
    corners: List[Tuple[float, float]]
    score: float
    viewport: Tuple[int, int, int, int]

    @property
    def viewport_left(self) -> int:
        return self.viewport[0]

    @property
    def viewport_top(self) -> int:
        return self.viewport[1]

    @property
    def viewport_width(self) -> int:
        return self.viewport[2]

    @property
    def viewport_height(self) -> int:
        return self.viewport[3]


def detect_document_corners_scored(
    rgb: np.ndarray, resample: int = Image.Resampling.BOX
) -> Optional[ScoredQuadPy]:
    """Mirrors `detectDocumentCornersScored` in `lib/imaging/document_detector.dart`."""
    h, w = rgb.shape[:2]
    if w < 20 or h < 20:
        return None

    def run_on_active(
        active_rgb: np.ndarray, vp: Tuple[int, int, int, int]
    ) -> Optional[ScoredQuadPy]:
        fine_rgb = _resize_box(active_rgb, FINE_SIDE, resample=resample)
        coarse_rgb = _resize_box(active_rgb, COARSE_SIDE, resample=resample)
        ff = _FieldPy.build(fine_rgb, smooth=False)
        cf = _FieldPy.build(coarse_rgb, smooth=True)
        scale_k = ff.width / float(cf.width)
        p1 = _run_detector_pass(cf, ff, scale_k, 1.0, 0.5, 0.3)
        p2 = _run_detector_pass(cf, ff, scale_k, 0.5, 0.7, 0.5)
        if p1 is None and p2 is None:
            return None
        picked = p2 if p1 is None else (p1 if p2 is None else (p2 if p2[1] > p1[1] + 0.04 else p1))
        quad, val = picked
        fw, fh = max(1, ff.width - 1), max(1, ff.height - 1)
        full_w, full_h = max(1, w - 1), max(1, h - 1)
        vp_left, vp_top, vp_w, vp_h = vp
        vp_mx, vp_my = max(0, vp_w - 1), max(0, vp_h - 1)
        norm = [
            (
                min(1.0, max(0.0, (vp_left + (px / fw) * vp_mx) / full_w)),
                min(1.0, max(0.0, (vp_top + (py / fh) * vp_my) / full_h)),
            )
            for px, py in quad
        ]
        # CropGeometry validation check
        if len(norm) != 4 or polygon_area_abs(norm) <= 1e-6:
            return None
        return ScoredQuadPy(corners=norm, score=val, viewport=vp)

    vp = detect_letterbox_viewport(rgb)
    has_lb = vp[0] > 0 or vp[1] > 0 or vp[2] < w or vp[3] < h
    if has_lb:
        sub = rgb[vp[1] : vp[1] + vp[3], vp[0] : vp[0] + vp[2]]
        res = run_on_active(sub, vp)
        if res is not None:
            return res
    return run_on_active(rgb, (0, 0, w, h))


def exact_dart_detector_v2(
    rgb: np.ndarray, resample: int = Image.Resampling.BOX
) -> Optional[Tuple[List[Tuple[float, float]], float]]:
    scored = detect_document_corners_scored(rgb, resample=resample)
    return (scored.corners, scored.score) if scored is not None else None


# ---------------------------------------------------------------------------
# Exact Port of `lib/imaging/document_segmenter.dart`
# ---------------------------------------------------------------------------


@dataclass
class SegmentCandidatePy:
    region: List[float]
    reason: str
    corners: Optional[List[Tuple[float, float]]] = None
    detection_confidence: Optional[float] = None
    producer: str = "segmenter"
    min_auto_accept_confidence: Optional[float] = None
    touches_frame_edge: bool = False


@dataclass
class RejectedRegionPy:
    region: List[float]
    rejection: str
    aspect: float
    border_sides: int
    fill: float
    crop_width: int
    crop_height: int


@dataclass
class SegmentationResultPy:
    multi: bool
    candidates: List[SegmentCandidatePy]
    rejected: List[RejectedRegionPy] = field(default_factory=list)


def _norm_box_iou(a: Sequence[float], b: Sequence[float]) -> float:
    l, t = max(a[0], b[0]), max(a[1], b[1])
    r, bo = min(a[2], b[2]), min(a[3], b[3])
    if r <= l or bo <= t:
        return 0.0
    inter = (r - l) * (bo - t)
    aa = (a[2] - a[0]) * (a[3] - a[1])
    ab = (b[2] - b[0]) * (b[3] - b[1])
    u = aa + ab - inter
    return inter / u if u > 0.0 else 0.0


def _otsu128(values: np.ndarray, max_val: float, bins: int = 128) -> float:
    if max_val <= 0.0:
        return 0.0
    idx = np.clip(np.rint(values.ravel() / max_val * (bins - 1)).astype(np.int32), 0, bins - 1)
    hist = np.bincount(idx, minlength=bins).astype(np.float64)
    total = float(values.size)
    s_all = float(np.sum(np.arange(bins, dtype=np.float64) * hist))
    wb = 0.0
    sb = 0.0
    best = 0.0
    best_thr = bins // 2
    for i in range(bins):
        wb += hist[i]
        if wb == 0.0:
            continue
        wf = total - wb
        if wf == 0.0:
            break
        sb += i * hist[i]
        between = wb * wf * (sb / wb - (s_all - sb) / wf) ** 2
        if between > best:
            best = between
            best_thr = i
    return best_thr / float(bins - 1) * max_val


def _suppress_duplicates(cands: List[SegmentCandidatePy]) -> List[SegmentCandidatePy]:
    kept: List[SegmentCandidatePy] = []
    for cand in cands:
        dup_idx = None
        for i, prev in enumerate(kept):
            same = (
                polygon_iou(cand.corners, prev.corners) >= 0.5
                if (cand.corners is not None and prev.corners is not None)
                else _norm_box_iou(cand.region, prev.region) >= 0.6
            )
            if same:
                dup_idx = i
                break
        if dup_idx is None:
            kept.append(cand)
        elif kept[dup_idx].corners is None and cand.corners is not None:
            kept[dup_idx] = cand
    return kept


def _measure_box(
    box: Tuple[int, int, int, int, float], w: int, h: int, src_w: int, src_h: int
) -> Dict:
    l, t, r, b, area = box
    bw, bh = r - l + 1, b - t + 1
    fill = area / float(bw * bh)
    aspect = max(bw, bh) / float(max(1, min(bw, bh)))
    border_sides = (1 if l <= 1 else 0) + (1 if t <= 1 else 0) + (1 if r >= w - 2 else 0) + (1 if b >= h - 2 else 0)
    margin_x = 0.08 * bw
    margin_y = 0.08 * bh
    reg = [
        min(1.0, max(0.0, (l - margin_x) / max(1, w - 1))),
        min(1.0, max(0.0, (t - margin_y) / max(1, h - 1))),
        min(1.0, max(0.0, (r + margin_x) / max(1, w - 1))),
        min(1.0, max(0.0, (b + margin_y) / max(1, h - 1))),
    ]
    sl = int(round(reg[0] * (src_w - 1)))
    st = int(round(reg[1] * (src_h - 1)))
    sr = int(round(reg[2] * (src_w - 1)))
    sb = int(round(reg[3] * (src_h - 1)))
    sw = max(1, min(src_w - sl, sr - sl + 1))
    sh = max(1, min(src_h - st, sb - st + 1))
    crop_w = int(round(bw / float(w) * src_w))
    crop_h = int(round(bh / float(h) * src_h))
    return {
        "box": box,
        "fill": fill,
        "aspect": aspect,
        "border_sides": border_sides,
        "region": reg,
        "sub": (sl, st, sw, sh),
        "crop_w": crop_w,
        "crop_h": crop_h,
    }


def _rejection_for(m: Dict) -> Optional[str]:
    if m["border_sides"] >= 2:
        return "frameArtifact"
    if m["aspect"] > MAX_PLAUSIBLE_REGION_ASPECT:
        return "implausibleAspect"
    if min(m["crop_w"], m["crop_h"]) < MIN_USABLE_REGION_CROP_PX:
        return "unusableCrop"
    return None


def _segment_enclosed_multi_cards(rgb: np.ndarray) -> Optional[SegmentationResultPy]:
    """Mirrors `_segmentEnclosedMultiCards` in `lib/imaging/document_segmenter.dart`."""
    src_h, src_w = rgb.shape[:2]
    work = _resize_box(rgb, ENCLOSED_WORK_SIDE)
    h, w = work.shape[:2]
    n = w * h
    if w < 40 or h < 40:
        return None
    f = _FieldPy.build(work, smooth=True)
    p85 = float(np.sort(f.mag.ravel())[int(round((n - 1) * 0.85))])
    thr = max(5.0, 0.35 * p85)
    edge = (f.mag >= thr).astype(np.uint8)
    closed = _morph(_morph(edge, 3, True), 3, False)
    filled = _fill_holes(closed)

    comps0 = _components4(filled)
    if comps0:
        comps0.sort(key=len, reverse=True)
        big = comps0[0]
        if len(big) > 0.55 * n:
            arr_b = np.asarray(big, dtype=np.int32)
            xs, ys = arr_b % w, arr_b // w
            x0, x1, y0, y1 = int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())
            inner = closed.copy()
            inner[: min(h, y0 + 6), :] = 0
            inner[max(0, y1 - 5) :, :] = 0
            inner[:, : min(w, x0 + 6)] = 0
            inner[:, max(0, x1 - 5) :] = 0
            filled = _fill_holes(inner)

    solid = _morph(_morph(filled, 5, False), 5, True)
    for by_col in (True, False):
        for pts in _components4(solid):
            if len(pts) < 0.05 * n:
                continue
            arr_p = np.asarray(pts, dtype=np.int32)
            xs, ys = arr_p % w, arr_p // w
            left, right, top, bottom = int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())
            bw, bh = right - left + 1, bottom - top + 1
            span = bw if by_col else bh
            cross = bh if by_col else bw
            counts = np.bincount((xs - left) if by_col else (ys - top), minlength=span)
            c0, c1 = int(math.floor(0.25 * span)), int(math.floor(0.75 * span))
            if c1 > c0 + 4:
                v_idx = int(c0 + np.argmin(counts[c0:c1]))
                p1 = int(counts[:v_idx].max()) if v_idx > 0 else 0
                p2 = int(counts[v_idx + 1 :].max()) if v_idx + 1 < span else 0
                min_peak = min(p1, p2) / float(cross)
                v_occ = counts[v_idx] / float(cross)
                if min_peak >= 0.60 and v_occ < 0.60 * min_peak:
                    if by_col:
                        neck = left + v_idx
                        solid[top : bottom + 1, max(0, neck - 2) : min(w, neck + 3)] = 0
                    else:
                        neck = top + v_idx
                        solid[max(0, neck - 2) : min(h, neck + 3), left : right + 1] = 0

    raw: List[Tuple[np.ndarray, Tuple[int, int, int, int, float]]] = []
    for pts in _components4(solid):
        arr_p = np.asarray(pts, dtype=np.int32)
        xs, ys = arr_p % w, arr_p // w
        l, r, t, b = int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())
        bw, bh = r - l + 1, b - t + 1
        area = float(len(pts))
        fill = area / float(bw * bh)
        aspect = max(bw, bh) / float(max(1, min(bw, bh)))
        bs = (1 if l <= 1 else 0) + (1 if t <= 1 else 0) + (1 if r >= w - 2 else 0) + (1 if b >= h - 2 else 0)
        if area >= 0.025 * n and fill >= 0.55 and aspect <= MAX_PLAUSIBLE_REGION_ASPECT and bs < 2 and bw * bh <= 0.50 * n:
            raw.append((arr_p, (l, t, r, b, area)))

    if len(raw) < 2:
        return None
    max_area = max(item[1][4] for item in raw)
    filtered = [item for item in raw if item[1][4] >= 0.25 * max_area]
    if len(filtered) < 2:
        return None
    row_band = max(1, int(round(h * 0.08)))
    filtered.sort(key=lambda it: (it[1][1] // row_band, it[1][0]))

    cands: List[SegmentCandidatePy] = []
    pad = 28
    for arr_p, box in filtered[:MAX_SEGMENT_CANDIDATES]:
        m = _measure_box(box, w, h, src_w, src_h)
        if _rejection_for(m) is not None:
            continue
        l, t, r, b, _ = box
        bw, bh = r - l + 1, b - t + 1
        mw, mh = bw + 2 * pad, bh + 2 * pad
        yy_g, xx_g = np.indices((mh, mw))
        base_v = (18 + (((xx_g + yy_g) & 1) * 14)).astype(np.uint8)
        mask_sub = np.stack([base_v, base_v + 4, base_v + 8], axis=2)
        mask_sub[(arr_p // w) - t + pad, (arr_p % w) - l + pad] = (242, 242, 240)
        det = detect_document_corners_scored(mask_sub)
        if det is None:
            continue
        mapped = [
            (
                min(1.0, max(0.0, ((l - pad) + px * (mw - 1)) / max(1, w - 1))),
                min(1.0, max(0.0, ((t - pad) + py * (mh - 1)) / max(1, h - 1))),
            )
            for px, py in det.corners
        ]
        if not assess_quad(mapped, src_w, src_h).acceptable:
            continue
        support = min(0.9, max(0.0, 0.45 + 0.5 * m["fill"]))
        cands.append(
            SegmentCandidatePy(
                region=m["region"],
                corners=mapped,
                detection_confidence=support,
                reason="enclosed-component-support",
            )
        )
    dedup = _suppress_duplicates(cands)
    if len(dedup) < 2 or sum(1 for c in dedup if c.corners is not None) < 2:
        return None
    return SegmentationResultPy(multi=True, candidates=dedup, rejected=[])


def segment_decoded(rgb: np.ndarray) -> SegmentationResultPy:
    """Mirrors `segmentDecoded` in `lib/imaging/document_segmenter.dart`."""
    src_h, src_w = rgb.shape[:2]
    if src_w < 32 or src_h < 32:
        return SegmentationResultPy(multi=False, candidates=[], rejected=[])
    work = _resize_box(rgb, SEGMENT_WORK_SIDE)
    h, w = work.shape[:2]
    total = float(w * h)

    border_mask = np.zeros((h, w), dtype=bool)
    border_mask[:2, :] = True
    border_mask[-2:, :] = True
    border_mask[:, :2] = True
    border_mask[:, -2:] = True
    bg_r = _dart_median(work[:, :, 0][border_mask].tolist())
    bg_g = _dart_median(work[:, :, 1][border_mask].tolist())
    bg_b = _dart_median(work[:, :, 2][border_mask].tolist())
    bg_lum = 0.299 * bg_r + 0.587 * bg_g + 0.114 * bg_b

    dist = (
        np.abs(work[:, :, 0] - bg_r)
        + np.abs(work[:, :, 1] - bg_g)
        + np.abs(work[:, :, 2] - bg_b)
    ).astype(np.float32)
    max_dist = float(np.max(dist))
    if max_dist < 30.0:
        if bg_lum >= 225.0:
            enc = _segment_enclosed_multi_cards(rgb)
            if enc is not None:
                return enc
        return SegmentationResultPy(multi=False, candidates=[], rejected=[])

    thr = max(30.0, _otsu128(dist, max_dist, bins=128))
    fg = (dist >= thr).astype(np.uint8)

    boxes: List[Tuple[int, int, int, int, float]] = []
    for pts in _components4(fg):
        if len(pts) < total * 0.015:
            continue
        arr_p = np.asarray(pts, dtype=np.int32)
        xs, ys = arr_p % w, arr_p // w
        l, r, t, b = int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())
        bw, bh = r - l + 1, b - t + 1
        area = float(len(pts))
        if bw < 10 or bh < 10:
            continue
        if area > total * 0.9:
            continue
        if area / float(bw * bh) < 0.35:
            continue
        boxes.append((l, t, r, b, area))

    # Overlap / gap merge matching `_mergeOverlapping`
    merged = list(boxes)
    changed = True
    while changed:
        changed = False
        i = 0
        while i < len(merged):
            j = i + 1
            while j < len(merged):
                a, b = merged[i], merged[j]
                gap = max(2.0, 0.01 * min(w, h))
                if not (a[2] + gap < b[0] or b[2] + gap < a[0] or a[3] + gap < b[1] or b[3] + gap < a[1]):
                    merged[i] = (min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]), a[4] + b[4])
                    merged.pop(j)
                    changed = True
                else:
                    j += 1
            i += 1

    measured = [_measure_box(b, w, h, src_w, src_h) for b in merged]
    row_band = max(1, int(round(h * 0.08)))
    measured.sort(key=lambda m: (m["box"][1] // row_band, m["box"][0]))

    accepted: List[Dict] = []
    rejected: List[RejectedRegionPy] = []
    for m in measured:
        rej = _rejection_for(m)
        if rej is None:
            accepted.append(m)
        else:
            rejected.append(
                RejectedRegionPy(
                    region=m["region"],
                    rejection=rej,
                    aspect=m["aspect"],
                    border_sides=m["border_sides"],
                    fill=m["fill"],
                    crop_width=m["crop_w"],
                    crop_height=m["crop_h"],
                )
            )

    if len(accepted) > MAX_SEGMENT_CANDIDATES:
        by_area = sorted(accepted, key=lambda m: m["box"][4], reverse=True)
        keep_ids = {id(m) for m in by_area[:MAX_SEGMENT_CANDIDATES]}
        new_acc = []
        for m in accepted:
            if id(m) in keep_ids:
                new_acc.append(m)
            else:
                rejected.append(
                    RejectedRegionPy(
                        region=m["region"],
                        rejection="candidateCap",
                        aspect=m["aspect"],
                        border_sides=m["border_sides"],
                        fill=m["fill"],
                        crop_width=m["crop_w"],
                        crop_height=m["crop_h"],
                    )
                )
        accepted = new_acc

    if not accepted:
        if not rejected and bg_lum >= 225.0:
            enc = _segment_enclosed_multi_cards(rgb)
            if enc is not None:
                return enc
        return SegmentationResultPy(multi=False, candidates=[], rejected=rejected)

    cands: List[SegmentCandidatePy] = []
    for m in accepted:
        sl, st, sw, sh = m["sub"]
        sub = rgb[st : st + sh, sl : sl + sw]
        det = detect_document_corners_scored(sub)
        if det is None:
            cands.append(SegmentCandidatePy(region=m["region"], reason="no-trustworthy-quad"))
            continue
        mapped = [
            (
                min(1.0, max(0.0, (sl + px * (sw - 1)) / max(1, src_w - 1))),
                min(1.0, max(0.0, (st + py * (sh - 1)) / max(1, src_h - 1))),
            )
            for px, py in det.corners
        ]
        support = min(0.9, max(0.0, 0.45 + 0.5 * m["fill"]))
        cands.append(
            SegmentCandidatePy(
                region=m["region"],
                corners=mapped,
                detection_confidence=support,
                reason="component-support",
            )
        )

    dedup = _suppress_duplicates(cands)
    if len(accepted) == 1 and len(dedup) == 1 and dedup[0].corners is not None:
        single_sheet = accepted[0]["box"][4] > 0.55 * total
        if not rejected and (bg_lum >= 225.0 or single_sheet):
            enc = _segment_enclosed_multi_cards(rgb)
            if enc is not None:
                return enc
        return SegmentationResultPy(multi=False, candidates=[], rejected=rejected)

    quad_cnt = sum(1 for c in dedup if c.corners is not None)
    if len(dedup) < 2 or quad_cnt < 1:
        if not rejected and bg_lum >= 225.0:
            enc = _segment_enclosed_multi_cards(rgb)
            if enc is not None:
                return enc
    return SegmentationResultPy(
        multi=len(dedup) >= 2 and quad_cnt >= 1,
        candidates=dedup,
        rejected=rejected,
    )


# ---------------------------------------------------------------------------
# Exact Port of `lib/imaging/hybrid_boundary_arbitrator.dart`
# ---------------------------------------------------------------------------


def measure_quad_physics(
    rgb: np.ndarray, quad: Sequence[Tuple[float, float]]
) -> Dict[str, float]:
    """Mirrors `measureQuadPhysics` in `lib/imaging/hybrid_boundary_arbitrator.dart`."""
    h, w = rgb.shape[:2]
    sx, sy = float(max(1, w - 1)), float(max(1, h - 1))
    step_off = min(8.0, max(3.0, 0.008 * max(w, h)))
    out_off = min(18.0, max(6.0, 0.025 * max(w, h)))
    arr = rgb.astype(np.float64)

    all_steps: List[float] = []
    int_steps: List[float] = []
    valid_outs: List[List[float]] = []
    out_of_frame = 0

    for i in range(4):
        a, b = quad[i], quad[(i + 1) % 4]
        near_edge = (
            (a[0] <= 0.008 and b[0] <= 0.008)
            or (a[0] >= 0.992 and b[0] >= 0.992)
            or (a[1] <= 0.008 and b[1] <= 0.008)
            or (a[1] >= 0.992 and b[1] >= 0.992)
        )
        ax, ay = a[0] * sx, a[1] * sy
        bx, by = b[0] * sx, b[1] * sy
        length = math.hypot(bx - ax, by - ay)
        if length < 4.0:
            all_steps.append(0.0)
            out_of_frame += 1
            continue
        nx, ny = (by - ay) / length, -(bx - ax) / length
        diffs: List[float] = []
        out_r, out_g, out_b = [], [], []
        for k in range(20):
            t = 0.08 + 0.84 * k / 19.0
            px, py = ax + (bx - ax) * t, ay + (by - ay) * t
            ix, iy = int(round(px - nx * step_off)), int(round(py - ny * step_off))
            ox, oy = int(round(px + nx * step_off)), int(round(py + ny * step_off))
            if 0 <= ix < w and 0 <= iy < h and 0 <= ox < w and 0 <= oy < h:
                pin, pout = arr[iy, ix], arr[oy, ox]
                diffs.append(float(np.linalg.norm(pin - pout)))
            fx, fy = int(round(px + nx * out_off)), int(round(py + ny * out_off))
            if 0 <= fx < w and 0 <= fy < h:
                pf = arr[fy, fx]
                out_r.append(float(pf[0]))
                out_g.append(float(pf[1]))
                out_b.append(float(pf[2]))
        if near_edge or len(diffs) < 10:
            out_of_frame += 1
            all_steps.append(_dart_median(diffs) if diffs else 0.0)
        else:
            st_val = _dart_median(diffs)
            all_steps.append(st_val)
            int_steps.append(st_val)
            if len(out_r) >= 6:
                valid_outs.append([_dart_median(out_r), _dart_median(out_g), _dart_median(out_b)])

    max_dev = 0.0
    if len(valid_outs) >= 3:
        for i in range(len(valid_outs)):
            others = [valid_outs[j] for j in range(len(valid_outs)) if j != i]
            med = [_dart_median([o[c] for o in others]) for c in range(3)]
            dev = math.sqrt(sum((valid_outs[i][c] - med[c]) ** 2 for c in range(3)))
            if dev > max_dev:
                max_dev = dev

    edges = []
    for i in range(4):
        dx = (quad[(i + 1) % 4][0] - quad[i][0]) * sx
        dy = (quad[(i + 1) % 4][1] - quad[i][1]) * sy
        edges.append((dx, dy, math.hypot(dx, dy)))
    r02 = min(edges[0][2], edges[2][2]) / max(1e-6, max(edges[0][2], edges[2][2]))
    r13 = min(edges[1][2], edges[3][2]) / max(1e-6, max(edges[1][2], edges[3][2]))
    cos02 = -(edges[0][0] * edges[2][0] + edges[0][1] * edges[2][1]) / max(1e-6, edges[0][2] * edges[2][2])
    cos13 = -(edges[1][0] * edges[3][0] + edges[1][1] * edges[3][1]) / max(1e-6, edges[1][2] * edges[3][2])
    psim = min(1.0, max(0.0, 0.5 * (r02 * r13) + 0.5 * min(max(0.0, cos02), max(0.0, cos13))))

    return {
        "min_all_step": min(all_steps),
        "min_interior_step": min(int_steps) if int_steps else 0.0,
        "mean_step": sum(all_steps) / 4.0,
        "parallelogram_similarity": psim,
        "max_outside_dev": max_dev,
        "area_fraction": polygon_area_abs(quad),
        "out_of_frame_sides": out_of_frame,
        "interior_sides_count": len(int_steps),
        # Compatibility keys
        "min_step": min(all_steps),
        "planarity": psim,
        "clipped_sides": out_of_frame,
    }


def arbitrate_scene_boundaries(
    rgb: np.ndarray, ai_scene: Optional[SegmentationResultPy]
) -> SegmentationResultPy:
    """Mirrors `arbitrateSceneBoundaries` in `lib/imaging/hybrid_boundary_arbitrator.dart`."""
    h, w = rgb.shape[:2]
    if ai_scene is not None and ai_scene.multi and len(ai_scene.candidates) >= 2:
        cl_single = detect_document_corners_scored(rgb)
        single_m = measure_quad_physics(rgb, cl_single.corners) if cl_single is not None else None
        valid_cnt = 0
        strongest_sub = 0.0
        for c in ai_scene.candidates:
            if c.corners is None or (c.detection_confidence or 0.0) < 0.35:
                continue
            if not assess_quad(c.corners, w, h).acceptable:
                continue
            m = measure_quad_physics(rgb, c.corners)
            if m["min_all_step"] > strongest_sub:
                strongest_sub = float(m["min_all_step"])
            if m["min_all_step"] >= 20.0:
                valid_cnt += 1
        if valid_cnt < 2:
            return SegmentationResultPy(multi=False, candidates=[])
        if cl_single is not None and single_m is not None:
            all_inside = all(
                c.corners is not None and intersection_over_first(c.corners, cl_single.corners) >= 0.85
                for c in ai_scene.candidates
            )
            if all_inside and single_m["min_all_step"] > 2.2 * strongest_sub:
                return SegmentationResultPy(multi=False, candidates=[])
        return ai_scene

    cl_multi = segment_decoded(rgb)
    if cl_multi.multi and len(cl_multi.candidates) >= 2:
        valid_multi: List[SegmentCandidatePy] = []
        for c in cl_multi.candidates:
            if c.corners is None:
                continue
            if not assess_quad(c.corners, w, h).acceptable:
                continue
            if ai_scene is not None:
                m = measure_quad_physics(rgb, c.corners)
                valid_multi.append(
                    SegmentCandidatePy(
                        region=c.region,
                        corners=c.corners,
                        detection_confidence=0.0,
                        producer="segmenter",
                        min_auto_accept_confidence=0.55,
                        touches_frame_edge=bool(
                            c.touches_frame_edge or m["out_of_frame_sides"] > 0
                        ),
                        reason=c.reason,
                    )
                )
            else:
                valid_multi.append(c)
        if len(valid_multi) >= 2:
            return SegmentationResultPy(
                multi=True,
                candidates=valid_multi,
                rejected=cl_multi.rejected,
            )
    return SegmentationResultPy(multi=False, candidates=[])


def arbitrate_single_boundary(
    rgb: np.ndarray,
    ai_proposal: Optional[BoundaryProposalPy],
    extra_ai: Sequence[BoundaryProposalPy] = (),
    has_learned_model: bool = True,
) -> Optional[BoundaryProposalPy]:
    """Mirrors `arbitrateSingleBoundary` in `lib/imaging/hybrid_boundary_arbitrator.dart`."""
    h, w = rgb.shape[:2]
    all_ai = ([ai_proposal] if ai_proposal is not None else []) + list(extra_ai)

    best_ai: Optional[BoundaryProposalPy] = None
    best_ai_m: Optional[Dict[str, float]] = None
    best_sc = -1e18
    for p in all_ai:
        if p.corners is None or len(p.corners) != 4:
            continue
        if not assess_quad(p.corners, w, h).acceptable:
            continue
        m = measure_quad_physics(rgb, p.corners)
        sc = m["min_all_step"] + 0.25 * m["mean_step"] + 40.0 * m["area_fraction"]
        if sc > best_sc:
            best_sc = sc
            best_ai = p
            best_ai_m = m

    cl = detect_document_corners_scored(rgb)
    valid_cl = cl if (cl is not None and assess_quad(cl.corners, w, h).acceptable) else None
    cl_m = measure_quad_physics(rgb, valid_cl.corners) if valid_cl is not None else None

    if not has_learned_model:
        if valid_cl is None or cl_m is None:
            return None
        return BoundaryProposalPy(
            producer="wholeFrameDetector",
            corners=valid_cl.corners,
            touches_frame_edge=bool(cl_m["out_of_frame_sides"] > 0),
        )

    enclosed_inner = (
        best_ai is not None
        and best_ai.corners is not None
        and best_ai_m is not None
        and valid_cl is not None
        and cl_m is not None
        and cl_m["out_of_frame_sides"] == 0
        and cl_m["area_fraction"] >= 1.25 * best_ai_m["area_fraction"]
        and cl_m["min_all_step"] > best_ai_m["min_all_step"] * 2.0
        and intersection_over_first(best_ai.corners, valid_cl.corners) >= 0.90
    )

    if (
        not enclosed_inner
        and best_ai is not None
        and best_ai_m is not None
        and best_ai_m["out_of_frame_sides"] == 0
        and best_ai_m["min_all_step"] >= 35.0
    ):
        chosen = best_ai.corners
        assert chosen is not None
        if valid_cl is not None and cl_m is not None:
            iou = polygon_iou(chosen, valid_cl.corners)
            if (
                iou >= 0.85
                and cl_m["out_of_frame_sides"] == 0
                and cl_m["min_all_step"] > best_ai_m["min_all_step"] * 1.15
            ):
                chosen = valid_cl.corners
        return BoundaryProposalPy(
            producer=best_ai.producer,
            corners=chosen,
            region=best_ai.region,
            imposed_aspect=best_ai.imposed_aspect,
            model_confidence=best_ai.model_confidence,
            min_auto_accept_confidence=best_ai.min_auto_accept_confidence,
            touches_frame_edge=best_ai.touches_frame_edge,
        )

    if valid_cl is not None and cl_m is not None:
        if (
            cl_m["interior_sides_count"] >= 1
            and cl_m["mean_step"] >= 25.0
            and cl_m["min_interior_step"] >= 10.0
        ):
            unverified_conf = (
                best_ai.model_confidence
                if (
                    best_ai is not None
                    and best_ai.model_confidence is not None
                    and best_ai.min_auto_accept_confidence is not None
                    and best_ai.model_confidence < best_ai.min_auto_accept_confidence
                )
                else 0.0
            )
            return BoundaryProposalPy(
                producer="wholeFrameDetector",
                corners=valid_cl.corners,
                imposed_aspect=best_ai.imposed_aspect if best_ai else None,
                model_confidence=unverified_conf,
                min_auto_accept_confidence=(
                    best_ai.min_auto_accept_confidence
                    if (best_ai and best_ai.min_auto_accept_confidence is not None)
                    else 0.55
                ),
                touches_frame_edge=bool(cl_m["out_of_frame_sides"] > 0),
            )

    if best_ai is not None and best_ai_m is not None:
        raw_c = best_ai.model_confidence
        min_auto = best_ai.min_auto_accept_confidence if best_ai.min_auto_accept_confidence is not None else 0.55
        return BoundaryProposalPy(
            producer=best_ai.producer,
            corners=best_ai.corners,
            region=best_ai.region,
            imposed_aspect=best_ai.imposed_aspect,
            model_confidence=raw_c if (raw_c is not None and raw_c < min_auto) else 0.0,
            min_auto_accept_confidence=min_auto,
            touches_frame_edge=bool(best_ai.touches_frame_edge or best_ai_m["out_of_frame_sides"] > 0),
        )

    return ai_proposal


# ---------------------------------------------------------------------------
# Official Frozen `ScanIdDocNet-v1` ONNX Runner (`tool/ai/inference_pipeline.py`)
# ---------------------------------------------------------------------------


_CACHED_ONNX_DETECTOR = None


def run_onnx_ai_scene(
    preview_rgb: np.ndarray,
    models_dir: Path,
) -> Tuple[SegmentationResultPy, List[BoundaryProposalPy]]:
    """Runs the official frozen `TwoStageOnnxDetector` matching `lib/imaging/ai_document_detector.dart`."""
    import sys as _sys

    repo_root = models_dir.resolve().parents[1]
    if str(repo_root) not in _sys.path:
        _sys.path.insert(0, str(repo_root))
    from tool.ai.inference_pipeline import FrozenThresholds, TwoStageOnnxDetector

    global _CACHED_ONNX_DETECTOR
    if _CACHED_ONNX_DETECTOR is None:
        manifest = json.loads((models_dir / "MODEL_MANIFEST.json").read_text(encoding="utf-8"))
        ft = FrozenThresholds(**manifest.get("frozen_thresholds", {}))
        _CACHED_ONNX_DETECTOR = TwoStageOnnxDetector(
            models_dir / "scanid_stage1_det_v1.onnx",
            models_dir / "scanid_stage2_corners_v1.onnx",
            thresholds=ft,
        )

    scene = _CACHED_ONNX_DETECTOR.detect(preview_rgb)
    proposals: List[BoundaryProposalPy] = []
    seg_cands: List[SegmentCandidatePy] = []
    for c in scene.candidates:
        pts = [(float(p[0]), float(p[1])) for p in c.corners]
        reg = [float(v) for v in c.region]
        verdict_val = c.verdict.value if hasattr(c.verdict, "value") else str(c.verdict)
        gate_conf = float(c.geom_confidence) if verdict_val == "accepted" else 0.0
        edge_touch = int(c.frame_touch_count) > 0
        proposals.append(
            BoundaryProposalPy(
                producer="learnedModel",
                corners=pts,
                region=None,
                model_confidence=gate_conf,
                min_auto_accept_confidence=0.55,
                touches_frame_edge=edge_touch,
            )
        )
        seg_cands.append(
            SegmentCandidatePy(
                region=reg,
                reason="ai-stage1-stage2",
                corners=pts,
                detection_confidence=gate_conf,
                producer="learnedModel",
                min_auto_accept_confidence=0.55,
                touches_frame_edge=edge_touch,
            )
        )

    if len(seg_cands) == 0:
        ai_seg = SegmentationResultPy(multi=False, candidates=[])
    elif len(seg_cands) == 1:
        ai_seg = SegmentationResultPy(multi=False, candidates=seg_cands)
    else:
        ai_seg = SegmentationResultPy(multi=True, candidates=seg_cands)
    return ai_seg, proposals


_CATALOG_NATURAL_ASPECTS: Dict[str, float] = {
    "unifiedNationalId": 85.6 / 53.98,
    "residenceCard": 92.4 / 62.8,
    "passport": 125.0 / 88.0,
    "rationCard": 287.0 / 52.0,
}

_NAME_TOKENS: List[Tuple[str, List[str]]] = [
    ("rationCard", ["تموين", "تموينيه", "التموينيه", "ration"]),
    ("residenceCard", ["بطاقةالسكن", "السكن", "سكن", "residence", "housing"]),
    ("passport", ["جواز", "passport"]),
    (
        "unifiedNationalId",
        [
            "البطاقةالوطنية",
            "بطاقةوطنية",
            "البطاقةالموحدة",
            "بطاقةموحدة",
            "الوطنيةالموحدة",
            "الهويه",
            "unifiednational",
            "nationalid",
        ],
    ),
]


def _normalize_doc_name(value: str) -> str:
    import re as _re

    out = value.lower()
    out = _re.sub(r"[\u064B-\u065F\u0670]", "", out)
    out = out.replace("ة", "ه").replace("ى", "ي")
    out = _re.sub(r"[\s_\-.]+", "", out)
    return out


def suggest_document_type_py(
    name: str, width: int, height: int, full_frame: bool = False
) -> Tuple[str, float]:
    """Mirrors `suggestDocumentType` in `lib/domain/document_kind.dart`."""
    norm = _normalize_doc_name(name)
    for kind, tokens in _NAME_TOKENS:
        if any(_normalize_doc_name(t) in norm for t in tokens):
            return kind, 0.98
    if width <= 0 or height <= 0:
        return "unknown", 0.0
    ratio = max(width, height) / min(width, height)
    if full_frame and any(abs(ratio / f - 1.0) < 0.01 for f in (4.0 / 3.0, 3.0 / 2.0, 16.0 / 9.0)):
        return "unknown", 0.0
    best_kind: Optional[str] = None
    best_err = float("inf")
    second_err = float("inf")
    for kind in ("unifiedNationalId", "residenceCard", "passport", "rationCard"):
        err = abs(ratio / _CATALOG_NATURAL_ASPECTS[kind] - 1.0)
        if err < best_err:
            second_err = best_err
            best_err = err
            best_kind = kind
        elif err < second_err:
            second_err = err
    if best_kind is None or best_err > 0.04:
        return "unknown", 0.0
    closeness = 1.0 - best_err / 0.04
    separation = (
        max(0.0, min(1.0, (second_err - best_err) / 0.04))
        if math.isfinite(second_err)
        else 1.0
    )
    return best_kind, max(0.5, min(0.95, 0.5 + 0.45 * closeness * separation))


def classify_claimed_aspect_py(
    name: str,
    corners: Optional[Sequence[Tuple[float, float]]],
    region: Optional[Sequence[float]],
    source_width: int,
    source_height: int,
) -> Optional[float]:
    """Mirrors `_analyzeDetection` classification -> `claimedNatural?.aspect` in `lib/application/recognition_pipeline.dart`."""
    assess = (
        assess_quad(corners, source_width, source_height)
        if corners is not None
        else None
    )
    quad_aspect = assess.aspect if (assess is not None and assess.acceptable) else None
    boundary_detected = quad_aspect is not None
    if quad_aspect is not None:
        w = max(1, int(round(1000.0 * quad_aspect)))
        h = 1000
    elif region is not None and len(region) == 4:
        rw = abs(region[2] - region[0]) * source_width
        rh = abs(region[3] - region[1]) * source_height
        asp = 1.0 if rh <= 0 else rw / rh
        w = max(1, int(round(1000.0 * asp)))
        h = 1000
    else:
        w = source_width
        h = source_height

    labelled_k, labelled_c = suggest_document_type_py(
        name, w, h, full_frame=not boundary_detected
    )
    shape_k, shape_c = suggest_document_type_py(
        "x", w, h, full_frame=not boundary_detected
    )
    votes: Dict[str, List[float]] = {}
    if labelled_k != "unknown" and (labelled_k != shape_k or labelled_c != shape_c):
        votes.setdefault(labelled_k, []).append(labelled_c)
    if shape_k != "unknown":
        votes.setdefault(shape_k, []).append(shape_c)

    order = ["unifiedNationalId", "residenceCard", "passport", "rationCard", "other"]
    winner = "unknown"
    winner_score = 0.0
    for k in order:
        if k in votes:
            best = max(votes[k])
            if best > winner_score:
                winner_score = best
                winner = k
    return _CATALOG_NATURAL_ASPECTS.get(winner)


def detect_full_pipeline(
    full_rgb: np.ndarray,
    use_learned_model: bool = True,
    models_dir: Optional[Path] = None,
    filename: str = "x",
) -> List[BoundaryDecisionPy]:
    """Exact end-to-end mirror of `LocalImageEditor` + `RecognitionPipeline.analyze` + `verifyBoundary`."""
    resolved_models = models_dir or (Path(__file__).resolve().parents[2] / "assets" / "models")
    preview = _resize_box(full_rgb, 2000, resample=Image.Resampling.BOX).astype(np.uint8)
    ph, pw = preview.shape[:2]

    ai_seg: Optional[SegmentationResultPy] = None
    ai_proposals: List[BoundaryProposalPy] = []
    if use_learned_model and (resolved_models / "MODEL_MANIFEST.json").exists():
        ai_seg, ai_proposals = run_onnx_ai_scene(preview, resolved_models)

    seg = arbitrate_scene_boundaries(preview, ai_seg)
    if len(seg.candidates) > 0:
        decisions: List[BoundaryDecisionPy] = []
        for c in seg.candidates:
            eff_prod = c.producer or ("wholeFrameDetector" if c.region is None else "segmenter")
            claimed_aspect = classify_claimed_aspect_py(
                filename, c.corners, c.region, pw, ph
            )
            prop = BoundaryProposalPy(
                producer=eff_prod,
                corners=c.corners,
                region=c.region,
                imposed_aspect=claimed_aspect,
                model_confidence=(
                    None
                    if c.min_auto_accept_confidence is None
                    else c.detection_confidence
                ),
                min_auto_accept_confidence=c.min_auto_accept_confidence,
                touches_frame_edge=c.touches_frame_edge,
            )
            decisions.append(verify_boundary(prop, pw, ph))
        return decisions

    primary_ai = ai_proposals[0] if ai_proposals else None
    extra_ai = ai_proposals[1:] if len(ai_proposals) > 1 else []
    prop = arbitrate_single_boundary(
        preview,
        ai_proposal=primary_ai,
        extra_ai=extra_ai,
        has_learned_model=use_learned_model,
    )
    eff_corners = prop.corners if prop is not None else None
    eff_prod = prop.producer if prop is not None else "wholeFrameDetector"
    claimed_aspect = classify_claimed_aspect_py(
        filename, eff_corners, None, pw, ph
    )
    final_prop = BoundaryProposalPy(
        producer=eff_prod,
        corners=eff_corners,
        region=None,
        imposed_aspect=claimed_aspect,
        model_confidence=(
            None
            if (prop is None or prop.min_auto_accept_confidence is None)
            else prop.model_confidence
        ),
        min_auto_accept_confidence=(
            prop.min_auto_accept_confidence if prop is not None else None
        ),
        touches_frame_edge=prop.touches_frame_edge if prop is not None else False,
    )
    return [verify_boundary(final_prop, pw, ph)]
