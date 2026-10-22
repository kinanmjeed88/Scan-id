"""Faithful Python port of Scan-id's shipped classical boundary baseline
(`lib/imaging/document_detector.dart`, `lib/imaging/document_segmenter.dart`,
and `lib/domain/boundary_decision.dart`).

Used exclusively by `tool/ai/benchmark_eval.py` so the held-out benchmark
compares the exact pre-existing classical detector + segmenter + `verifyBoundary`
against the new `ScanIdDocNet-v1` two-stage AI + `verifyBoundary` under
identical inputs, coordinate conventions, and domain gates.
"""

from __future__ import annotations

from dataclasses import dataclass
import math

import cv2
import numpy as np

from tool.ai.dataset_gen import canonicalize_quad_clockwise_tl, polygon_area, polygon_iou
from tool.ai.inference_pipeline import (
    Verdict,
    assess_quad_domain,
    count_frame_touches,
)


@dataclass
class ClassicalCandidate:
    corners: np.ndarray | None  # [4, 2] normalized clockwise TL..BL, or None if unresolved region
    region: list[float]  # [left, top, right, bottom] normalized
    confidence: float
    verdict: Verdict
    reasons: list[str]


@dataclass
class ClassicalResult:
    multi: bool
    candidates: list[ClassicalCandidate]


def _order_quad(pts: np.ndarray) -> np.ndarray:
    return canonicalize_quad_clockwise_tl(pts.astype(np.float32))


def _enclosing_quad_from_hull(hull_pts: np.ndarray) -> np.ndarray | None:
    if len(hull_pts) < 4:
        return None
    peri = float(cv2.arcLength(hull_pts.astype(np.float32), True))
    for eps_mul in (0.015, 0.025, 0.04, 0.06, 0.09):
        approx = cv2.approxPolyDP(hull_pts.astype(np.float32), eps_mul * peri, True)
        if len(approx) == 4:
            return approx.reshape(4, 2)
    rect = cv2.minAreaRect(hull_pts.astype(np.float32))
    box = cv2.boxPoints(rect)
    return box.astype(np.float32)


def _classical_single_detect(rgb: np.ndarray) -> tuple[np.ndarray | None, float]:
    """Mirrors `suggestDocumentCorners` in `lib/imaging/document_detector.dart`:
    coarse 360px border k-means (k=3) + Otsu distance mask + Canny/Hough candidates,
    scored by edge gradient support, contrast, and texture-crossing penalty (`>= 0.45`)."""
    h0, w0 = rgb.shape[:2]
    if min(w0, h0) < 32:
        return None, 0.0

    scale = min(1.0, 360.0 / max(w0, h0))
    cw = max(24, int(round(w0 * scale)))
    ch = max(24, int(round(h0 * scale)))
    small = cv2.resize(rgb, (cw, ch), interpolation=cv2.INTER_AREA).astype(np.float32)

    band = max(2, int(round(min(cw, ch) * 0.02)))
    border_mask = np.zeros((ch, cw), dtype=bool)
    border_mask[:band, :] = True
    border_mask[-band:, :] = True
    border_mask[:, :band] = True
    border_mask[:, -band:] = True
    border_px = small[border_mask]  # [N, 3]

    # Deterministic 3-cluster k-means initialized at 0, N//2, N-1
    idxs = [0, len(border_px) // 2, len(border_px) - 1]
    centres = border_px[idxs].copy()
    labels = np.zeros(len(border_px), dtype=np.int32)
    for _ in range(8):
        dists = np.sum((border_px[:, None, :] - centres[None, :, :]) ** 2, axis=2)
        labels = np.argmin(dists, axis=1)
        for k in range(3):
            m = labels == k
            if np.any(m):
                centres[k] = border_px[m].mean(axis=0)

    kept = [centres[k] for k in range(3) if np.sum(labels == k) >= 0.10 * len(border_px)]
    if not kept:
        kept = [centres[0]]
    kept_arr = np.stack(kept, axis=0)

    flat_px = small.reshape(-1, 3)
    min_d2 = np.min(np.sum((flat_px[:, None, :] - kept_arr[None, :, :]) ** 2, axis=2), axis=1)
    dist_map = np.sqrt(min_d2).reshape(ch, cw)
    max_d = float(dist_map.max())
    if max_d < 1.0:
        return None, 0.0

    dist_u8 = np.clip((dist_map / max_d) * 255.0, 0, 255).astype(np.uint8)
    otsu_t, _ = cv2.threshold(dist_u8, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    thresh_val = max(18.0, (float(otsu_t) / 255.0) * max_d)
    mask = (dist_map > thresh_val).astype(np.uint8) * 255
    kern = np.ones((5, 5), np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kern)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kern)

    candidates_px: list[np.ndarray] = []
    cnts, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    cnts = sorted(cnts, key=cv2.contourArea, reverse=True)
    for c in cnts[:3]:
        area = float(cv2.contourArea(c))
        if area < 0.03 * cw * ch or area > 0.995 * cw * ch:
            continue
        hull = cv2.convexHull(c).reshape(-1, 2)
        q = _enclosing_quad_from_hull(hull)
        if q is not None:
            candidates_px.append(_order_quad(q))

    # Canny / contour quad fallback (mirrors Hough quad branch)
    gray = cv2.cvtColor(small.astype(np.uint8), cv2.COLOR_RGB2GRAY)
    blur = cv2.GaussianBlur(gray, (5, 5), 1.0)
    gx = cv2.Sobel(blur, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(blur, cv2.CV_32F, 0, 1, ksize=3)
    mag = np.hypot(gx, gy)
    nz = mag[mag > 4.0]
    low = float(np.percentile(nz, 70)) if len(nz) > 20 else 20.0
    edges = cv2.Canny(blur, max(15, int(low * 0.6)), max(40, int(low * 1.4)))
    edges_d = cv2.dilate(edges, np.ones((3, 3), np.uint8), iterations=1)
    ecnts, _ = cv2.findContours(edges_d, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    ecnts = sorted(ecnts, key=cv2.contourArea, reverse=True)
    for c in ecnts[:6]:
        area = float(cv2.contourArea(c))
        if area < 0.04 * cw * ch or area > 0.96 * cw * ch:
            continue
        hull = cv2.convexHull(c).reshape(-1, 2)
        q = _enclosing_quad_from_hull(hull)
        if q is not None:
            candidates_px.append(_order_quad(q))

    if not candidates_px:
        return None, 0.0

    best_q: np.ndarray | None = None
    best_score = -1.0
    for q in candidates_px:
        q_norm = np.clip(q / np.array([cw - 1.0, ch - 1.0], dtype=np.float32), 0.0, 1.0)
        issues, area_f, _ = assess_quad_domain(q_norm, cw, ch, min_area_fraction=0.03)
        if issues:
            continue
        supports: list[float] = []
        strengths: list[float] = []
        contrasts: list[float] = []
        textures: list[float] = []
        for s_i in range(4):
            a, b = q[s_i], q[(s_i + 1) % 4]
            length = float(np.linalg.norm(b - a))
            if length < 6.0:
                supports.append(0.0)
                strengths.append(0.0)
                continue
            on_b = (
                (a[0] <= 2.5 and b[0] <= 2.5)
                or (a[1] <= 2.5 and b[1] <= 2.5)
                or (a[0] >= cw - 3.5 and b[0] >= cw - 3.5)
                or (a[1] >= ch - 3.5 and b[1] >= ch - 3.5)
            )
            if on_b:
                supports.append(0.55)
                strengths.append(0.50)
                continue
            nx_v = float((b[1] - a[1]) / length)
            ny_v = float(-(b[0] - a[0]) / length)
            n_pts = max(12, min(80, int(length / 3)))
            hits = 0
            st_vals: list[float] = []
            cs_vals: list[float] = []
            in_px: list[np.ndarray] = []
            out_px: list[np.ndarray] = []
            for k in range(n_pts):
                t = 0.1 + 0.8 * (k / max(1, n_pts - 1))
                px_x = float(a[0] + (b[0] - a[0]) * t)
                px_y = float(a[1] + (b[1] - a[1]) * t)
                best_al = 0.0
                for o in range(-2, 3):
                    sx_i = int(round(px_x + nx_v * o))
                    sy_i = int(round(px_y + ny_v * o))
                    if 0 <= sx_i < cw and 0 <= sy_i < ch:
                        al = abs(float(gx[sy_i, sx_i]) * nx_v + float(gy[sy_i, sx_i]) * ny_v)
                        best_al = max(best_al, al)
                if best_al >= low:
                    hits += 1
                st_vals.append(best_al)
                xi, yi = int(round(px_x - nx_v * 4)), int(round(px_y - ny_v * 4))
                xo, yo = int(round(px_x + nx_v * 4)), int(round(px_y + ny_v * 4))
                if 0 <= xi < cw and 0 <= yi < ch and 0 <= xo < cw and 0 <= yo < ch:
                    pin = small[yi, xi]
                    pout = small[yo, xo]
                    cs_vals.append(float(np.linalg.norm(pin - pout)))
                    in_px.append(pin)
                    out_px.append(pout)
            supports.append(hits / n_pts)
            strengths.append(min(1.0, float(np.median(st_vals)) / max(1e-6, 2.5 * low)))
            if cs_vals:
                contrasts.append(float(np.median(cs_vals)))
            if len(in_px) >= 6:
                sp_in = float(np.mean(np.std(np.stack(in_px), axis=0)))
                sp_out = float(np.mean(np.std(np.stack(out_px), axis=0)))
                textures.append(min(sp_in, sp_out))

        if len(supports) < 4 or min(supports) < 0.35 or np.mean(supports) < 0.55:
            continue
        sat = [min(1.0, s / 0.9) for s in supports]
        contrast_sc = min(1.0, (float(np.mean(contrasts)) if contrasts else 0.0) / 40.0)
        textures.sort()
        tex_v = textures[1] if len(textures) >= 3 else 0.0
        penalty = max(0.0, min(1.0, (tex_v - 15.0) / 30.0))
        total = (
            0.40 * float(np.mean(sat))
            + 0.20 * min(sat)
            + 0.10 * contrast_sc
            + 0.15 * float(np.mean(strengths))
            + 0.10 * math.sqrt(max(0.0, area_f))
            - 0.30 * penalty
        )
        if total >= 0.45 and total > best_score:
            best_score = total
            best_q = q_norm

    return best_q, max(0.0, best_score)


def run_classical_pipeline(rgb: np.ndarray) -> ClassicalResult:
    """Mirrors Scan-id's classical `segmentDocuments` -> `suggestDocumentCorners` -> `verifyBoundary`."""
    h, w = rgb.shape[:2]
    if min(w, h) < 48:
        return ClassicalResult(multi=False, candidates=[])

    # 1. Multi-document Otsu foreground segmentation (mirrors `document_segmenter.dart`)
    scale = min(1.0, 512.0 / max(w, h))
    sw, sh = max(32, int(round(w * scale))), max(32, int(round(h * scale)))
    small = cv2.resize(rgb, (sw, sh), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(small, cv2.COLOR_RGB2GRAY)

    band = max(2, int(round(min(sw, sh) * 0.03)))
    border = np.concatenate([gray[:band, :].ravel(), gray[-band:, :].ravel(), gray[:, :band].ravel(), gray[:, -band:].ravel()])
    bg_med = float(np.median(border))
    diff = np.abs(gray.astype(np.float32) - bg_med).astype(np.uint8)
    otsu_v, mask = cv2.threshold(diff, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    if otsu_v < 14:
        mask[:] = 0
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))

    num_l, _, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    accepted_boxes: list[tuple[list[float], float]] = []
    for lbl in range(1, num_l):
        bx, by, bw, bh, area = [int(stats[lbl, k]) for k in range(5)]
        area_fr = area / float(sw * sh)
        fill = area / float(max(1, bw * bh))
        asp = max(bw, bh) / float(max(1, min(bw, bh)))
        touches = int(bx <= 1) + int(by <= 1) + int(bx + bw >= sw - 1) + int(by + bh >= sh - 1)
        if area_fr < 0.02 or area_fr > 0.90 or fill < 0.35 or asp > 5.5 or touches >= 3:
            continue
        mx, my = bw * 0.06, bh * 0.06
        r0 = max(0.0, (bx - mx) / sw)
        r1 = max(0.0, (by - my) / sh)
        r2 = min(1.0, (bx + bw + mx) / sw)
        r3 = min(1.0, (by + bh + my) / sh)
        accepted_boxes.append(([r0, r1, r2, r3], fill))

    accepted_boxes.sort(key=lambda item: (item[0][2] - item[0][0]) * (item[0][3] - item[0][1]), reverse=True)
    accepted_boxes = accepted_boxes[:6]

    if len(accepted_boxes) >= 2:
        cands: list[ClassicalCandidate] = []
        for reg, fill in accepted_boxes:
            x0, y0 = int(round(reg[0] * (w - 1))), int(round(reg[1] * (h - 1)))
            x1, y1 = int(round(reg[2] * (w - 1))), int(round(reg[3] * (h - 1)))
            if x1 - x0 < 32 or y1 - y0 < 32:
                continue
            sub = rgb[y0 : y1 + 1, x0 : x1 + 1]
            sub_q, _ = _classical_single_detect(sub)
            if sub_q is None:
                cands.append(ClassicalCandidate(None, reg, 0.0, "needsReview", ["unresolvedRegion"]))
                continue
            mapped = np.zeros((4, 2), dtype=np.float32)
            mapped[:, 0] = np.clip((x0 + sub_q[:, 0] * (x1 - x0)) / (w - 1.0), 0.0, 1.0)
            mapped[:, 1] = np.clip((y0 + sub_q[:, 1] * (y1 - y0)) / (h - 1.0), 0.0, 1.0)
            mapped = _order_quad(mapped)
            issues, area_f, geom_c = assess_quad_domain(mapped, w, h)
            det_conf = min(0.90, max(0.0, 0.45 + 0.50 * fill))
            if issues or area_f >= 0.94:
                continue
            touches = count_frame_touches(mapped, margin=0.012)
            conf = min(geom_c, det_conf)
            verdict: Verdict = "accepted" if (conf >= 0.55 and touches == 0) else "needsReview"
            reasons = [] if verdict == "accepted" else (["touchesFrameEdge"] if touches > 0 else ["lowConfidence"])
            cands.append(ClassicalCandidate(mapped, reg, conf, verdict, reasons))

        quad_cnt = sum(1 for c in cands if c.corners is not None)
        if len(cands) >= 2 and quad_cnt >= 1:
            return ClassicalResult(multi=True, candidates=cands)

    # 2. Whole-frame single-document detector (`suggestDocumentCorners` + `verifyBoundary`)
    q_single, score = _classical_single_detect(rgb)
    if q_single is None:
        return ClassicalResult(multi=False, candidates=[])

    issues, area_f, geom_c = assess_quad_domain(q_single, w, h)
    if issues or area_f >= 0.94:
        return ClassicalResult(multi=False, candidates=[])
    touches = count_frame_touches(q_single, margin=0.012)
    verdict_s: Verdict = "accepted" if (geom_c >= 0.55 and touches == 0) else "needsReview"
    reasons_s = [] if verdict_s == "accepted" else (["touchesFrameEdge"] if touches > 0 else ["lowConfidence"])
    reg_s = [float(q_single[:, 0].min()), float(q_single[:, 1].min()), float(q_single[:, 0].max()), float(q_single[:, 1].max())]
    return ClassicalResult(
        multi=False,
        candidates=[ClassicalCandidate(q_single, reg_s, geom_c, verdict_s, reasons_s)],
    )
