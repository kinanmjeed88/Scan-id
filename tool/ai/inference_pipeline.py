"""Deterministic reference inference & post-processing for ScanIdDocNet-v1.

Every formula in this module (half-pixel bilinear RGB resampling, Stage-1 shrunk
connected-component + center-peak proposal decoding, 22% ROI expansion, Stage-2
soft-argmax + subpixel offset decoding, neural perimeter line-integral support,
bounded local gradient snap, Sutherland-Hodgman Polygon NMS, and `verifyBoundary`
gating) matches `lib/imaging/ai_document_detector.dart` 1-to-1.
"""

from __future__ import annotations

from dataclasses import dataclass
from itertools import combinations
import math
from typing import Literal

import numpy as np
import onnxruntime as ort

from tool.ai.dataset_gen import (
    canonicalize_quad_clockwise_tl,
    clip_convex_polygon,
    polygon_area,
    polygon_iou,
)

Verdict = Literal["accepted", "needsReview", "rejected"]


@dataclass(frozen=True)
class FrozenThresholds:
    scene_prob_floor: float = 0.22
    shrunk_mask_thresh: float = 0.36
    center_peak_thresh: float = 0.28
    accept_roi_valid: float = 0.65
    accept_four_visible: float = 0.65
    accept_min_corner_peak: float = 0.50
    accept_mean_corner_peak: float = 0.64
    accept_min_edge_support: float = 0.24
    accept_mean_edge_support: float = 0.36
    review_roi_valid: float = 0.28
    review_min_corner_peak: float = 0.16
    review_mean_corner_peak: float = 0.30
    review_mean_edge_support: float = 0.20
    nms_polygon_iou: float = 0.35


@dataclass
class AiQuadCandidate:
    corners: np.ndarray  # [4, 2] normalized clockwise starting at TL
    region: list[float]  # [left, top, right, bottom] normalized
    confidence: float
    geom_confidence: float
    roi_valid_prob: float
    four_visible_prob: float
    min_corner_peak: float
    mean_corner_peak: float
    min_edge_support: float
    mean_edge_support: float
    frame_touch_count: int
    verdict: Verdict
    reasons: list[str]


@dataclass
class AiDetectionResult:
    scene_has_doc_prob: float
    scene_multi_prob: float
    multi: bool
    candidates: list[AiQuadCandidate]


def bilinear_resize_rgb_to_chw(
    rgb: np.ndarray,
    dst_w: int,
    dst_h: int,
    rx0: float = 0.0,
    ry0: float = 0.0,
    rx1: float = 1.0,
    ry1: float = 1.0,
) -> np.ndarray:
    """Exact half-pixel-centered bilinear ROI resample to float32 [1, 3, dst_h, dst_w] in [0, 1].
    Matches `resampleRoiToChw` in `lib/imaging/ai_document_detector.dart`."""
    sh, sw = rgb.shape[:2]
    x_start = rx0 * (sw - 1)
    y_start = ry0 * (sh - 1)
    span_w = max(1e-6, (rx1 - rx0) * (sw - 1))
    span_h = max(1e-6, (ry1 - ry0) * (sh - 1))

    xs = x_start + ((np.arange(dst_w, dtype=np.float32) + 0.5) / dst_w) * span_w
    ys = y_start + ((np.arange(dst_h, dtype=np.float32) + 0.5) / dst_h) * span_h
    xs = np.clip(xs, 0.0, sw - 1.0)
    ys = np.clip(ys, 0.0, sh - 1.0)

    x0 = np.floor(xs).astype(np.int32)
    y0 = np.floor(ys).astype(np.int32)
    x1 = np.minimum(x0 + 1, sw - 1)
    y1 = np.minimum(y0 + 1, sh - 1)
    wx = (xs - x0)[None, :, None]
    wy = (ys - y0)[:, None, None]

    f = rgb.astype(np.float32) * (1.0 / 255.0)
    p00 = f[y0[:, None], x0[None, :]]
    p01 = f[y0[:, None], x1[None, :]]
    p10 = f[y1[:, None], x0[None, :]]
    p11 = f[y1[:, None], x1[None, :]]

    top = p00 + (p01 - p00) * wx
    bot = p10 + (p11 - p10) * wx
    out = top + (bot - top) * wy
    return np.transpose(out, (2, 0, 1))[None].astype(np.float32)


def assess_quad_domain(
    corners: np.ndarray,
    source_w: int,
    source_h: int,
    min_area_fraction: float = 0.015,
    max_aspect_ratio: float = 7.0,
) -> tuple[list[str], float, float]:
    """Exact mirror of `lib/domain/quad_assessment.dart` (`assessQuad` + `geometryConfidence`)."""
    issues: list[str] = []
    if corners.shape != (4, 2) or source_w <= 0 or source_h <= 0:
        return ["wrongCornerCount"], 0.0, 0.0
    if not np.all(np.isfinite(corners)):
        return ["nonFinite"], 0.0, 0.0
    if np.any(corners < -1e-6) or np.any(corners > 1.0 + 1e-6):
        issues.append("outOfBounds")

    px = corners * np.array([max(1, source_w - 1), max(1, source_h - 1)], dtype=np.float64)
    sides = [float(np.linalg.norm(px[(i + 1) % 4] - px[i])) for i in range(4)]
    if (
        any(s < 1e-3 for s in sides)
        or float(np.linalg.norm(px[2] - px[0])) < 1e-3
        or float(np.linalg.norm(px[3] - px[1])) < 1e-3
    ):
        issues.append("duplicateCorner")
        return issues, 0.0, 0.0

    def seg_inter(a: np.ndarray, b: np.ndarray, c: np.ndarray, d: np.ndarray) -> bool:
        def cross(o: np.ndarray, p: np.ndarray, q: np.ndarray) -> float:
            return float((p[0] - o[0]) * (q[1] - o[1]) - (p[1] - o[1]) * (q[0] - o[0]))

        d1, d2 = cross(a, b, c), cross(a, b, d)
        d3, d4 = cross(c, d, a), cross(c, d, b)
        return (d1 * d2 < 0) and (d3 * d4 < 0)

    if seg_inter(px[0], px[1], px[2], px[3]) or seg_inter(px[1], px[2], px[3], px[0]):
        issues.append("selfIntersecting")

    cross_signs = []
    min_angle_deg = 180.0
    max_angle_deg = 0.0
    for i in range(4):
        prev_p = px[(i + 3) % 4]
        curr_p = px[i]
        next_p = px[(i + 1) % 4]
        v1 = curr_p - prev_p
        v2 = next_p - curr_p
        cr = float(v1[0] * v2[1] - v1[1] * v2[0])
        cross_signs.append(cr)
        u1 = prev_p - curr_p
        u2 = next_p - curr_p
        cos_a = float(np.dot(u1, u2) / max(1e-9, np.linalg.norm(u1) * np.linalg.norm(u2)))
        ang = math.degrees(math.acos(max(-1.0, min(1.0, cos_a))))
        min_angle_deg = min(min_angle_deg, ang)
        max_angle_deg = max(max_angle_deg, ang)

    if not (all(c > 0 for c in cross_signs) or all(c < 0 for c in cross_signs)):
        issues.append("nonConvex")

    area_px = 0.5 * abs(
        float(np.sum(px[:, 0] * np.roll(px[:, 1], -1) - np.roll(px[:, 0], -1) * px[:, 1]))
    )
    frame_area = float(max(1, (source_w - 1) * (source_h - 1)))
    area_frac = area_px / frame_area
    if area_frac < min_area_fraction:
        issues.append("tooSmall")

    mean_w = 0.5 * (sides[0] + sides[2])
    mean_h = 0.5 * (sides[1] + sides[3])
    aspect = max(mean_w, mean_h) / max(1e-6, min(mean_w, mean_h))
    if aspect > max_aspect_ratio:
        issues.append("extremeAspectRatio")

    opp_tb = max(sides[0], sides[2]) / max(1e-6, min(sides[0], sides[2]))
    opp_lr = max(sides[1], sides[3]) / max(1e-6, min(sides[1], sides[3]))
    max_opp = max(opp_tb, opp_lr)
    if max_opp > 3.2 or min_angle_deg < 24.0 or max_angle_deg > 162.0:
        issues.append("implausiblePerspective")

    if issues:
        return issues, area_frac, 0.0

    taper_score = max(0.0, min(1.0, 1.0 - (max_opp - 1.0) / 2.2))
    angle_score = max(0.0, min(1.0, (min_angle_deg - 24.0) / 50.0))
    geom_conf = 0.55 * taper_score + 0.45 * angle_score
    return [], area_frac, geom_conf


def count_frame_touches(
    corners: np.ndarray,
    edges: list[float] | None = None,
    margin: float = 0.016,
) -> int:
    touches = 0
    if np.any(corners[:, 0] <= margin):
        touches += 1
    if np.any(corners[:, 0] >= 1.0 - margin):
        touches += 1
    if np.any(corners[:, 1] <= margin):
        touches += 1
    if np.any(corners[:, 1] >= 1.0 - margin):
        touches += 1
    if touches == 0 and edges is not None and len(edges) == 4:
        edge_margin = 0.028
        for i in range(4):
            p1, p2 = corners[i], corners[(i + 1) % 4]
            near_border = (
                (p1[0] <= edge_margin and p2[0] <= edge_margin)
                or (p1[0] >= 1.0 - edge_margin and p2[0] >= 1.0 - edge_margin)
                or (p1[1] <= edge_margin and p2[1] <= edge_margin)
                or (p1[1] >= 1.0 - edge_margin and p2[1] >= 1.0 - edge_margin)
            )
            if near_border:
                others = [edges[j] for j in range(4) if j != i]
                if edges[i] < 0.48 and (sum(others) / 3.0) >= 0.70:
                    touches += 1
                    break
    return touches


def extract_stage1_proposals(
    dense_map: np.ndarray,
    scene_prob: np.ndarray,
    thresholds: FrozenThresholds,
) -> list[tuple[list[float], float]]:
    """Decode Stage-1 [7, 40, 40] into instance ROI boxes `([xmin, ymin, xmax, ymax], score)`."""
    center_map = dense_map[0]
    shrunk_map = dense_map[1]
    extents = dense_map[3:7]
    grid = center_map.shape[0]

    proposals: list[tuple[list[float], float]] = []

    for gy in range(grid):
        for gx in range(grid):
            val = float(center_map[gy, gx])
            if val < thresholds.center_peak_thresh:
                continue
            y0, y1 = max(0, gy - 1), min(grid, gy + 2)
            x0, x1 = max(0, gx - 1), min(grid, gx + 2)
            if val < float(center_map[y0:y1, x0:x1].max()):
                continue
            box_acc = np.zeros(4, dtype=np.float64)
            w_sum = 0.0
            for ny in range(y0, y1):
                for nx in range(x0, x1):
                    w = float(center_map[ny, nx]) * max(0.15, float(shrunk_map[ny, nx]))
                    cx_n = (nx + 0.5) / grid
                    cy_n = (ny + 0.5) / grid
                    box_acc[0] += w * (cx_n + float(extents[0, ny, nx]))
                    box_acc[1] += w * (cy_n + float(extents[1, ny, nx]))
                    box_acc[2] += w * (cx_n + float(extents[2, ny, nx]))
                    box_acc[3] += w * (cy_n + float(extents[3, ny, nx]))
                    w_sum += w
            if w_sum > 0:
                b_est = np.clip(box_acc / w_sum, 0.0, 1.0)
                if b_est[2] - b_est[0] > 0.05 and b_est[3] - b_est[1] > 0.05:
                    proposals.append(([float(x) for x in b_est], val))

    visited = np.zeros((grid, grid), dtype=bool)
    for gy in range(grid):
        for gx in range(grid):
            if visited[gy, gx] or shrunk_map[gy, gx] < thresholds.shrunk_mask_thresh:
                continue
            stack = [(gx, gy)]
            visited[gy, gx] = True
            cells: list[tuple[int, int]] = []
            while stack:
                cx_i, cy_i = stack.pop()
                cells.append((cx_i, cy_i))
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        nx, ny = cx_i + dx, cy_i + dy
                        if (
                            0 <= nx < grid
                            and 0 <= ny < grid
                            and not visited[ny, nx]
                            and shrunk_map[ny, nx] >= thresholds.shrunk_mask_thresh
                        ):
                            visited[ny, nx] = True
                            stack.append((nx, ny))
            if len(cells) < 2:
                continue
            box_acc = np.zeros(4, dtype=np.float64)
            w_sum = 0.0
            max_s = 0.0
            xs_c = [c[0] for c in cells]
            ys_c = [c[1] for c in cells]
            for nx, ny in cells:
                s_val = float(shrunk_map[ny, nx])
                c_val = float(center_map[ny, nx])
                w = s_val * (0.4 + 0.6 * c_val)
                max_s = max(max_s, 0.5 * (s_val + c_val))
                cx_n = (nx + 0.5) / grid
                cy_n = (ny + 0.5) / grid
                box_acc[0] += w * (cx_n + float(extents[0, ny, nx]))
                box_acc[1] += w * (cy_n + float(extents[1, ny, nx]))
                box_acc[2] += w * (cx_n + float(extents[2, ny, nx]))
                box_acc[3] += w * (cy_n + float(extents[3, ny, nx]))
                w_sum += w
            if w_sum > 0:
                reg_box = box_acc / w_sum
                cc_cx = (min(xs_c) + max(xs_c) + 1.0) * 0.5 / grid
                cc_cy = (min(ys_c) + max(ys_c) + 1.0) * 0.5 / grid
                cc_hw = ((max(xs_c) - min(xs_c) + 1.0) * 0.5 / grid) / 0.60
                cc_hh = ((max(ys_c) - min(ys_c) + 1.0) * 0.5 / grid) / 0.60
                geom_box = np.array([cc_cx - cc_hw, cc_cy - cc_hh, cc_cx + cc_hw, cc_cy + cc_hh])
                blended = np.clip(0.65 * reg_box + 0.35 * geom_box, 0.0, 1.0)
                if blended[2] - blended[0] > 0.05 and blended[3] - blended[1] > 0.05:
                    proposals.append(([float(x) for x in blended], max_s))

    def box_iou(a: list[float], b: list[float]) -> float:
        ix0, iy0 = max(a[0], b[0]), max(a[1], b[1])
        ix1, iy1 = min(a[2], b[2]), min(a[3], b[3])
        inter = max(0.0, ix1 - ix0) * max(0.0, iy1 - iy0)
        if inter <= 0.0:
            return 0.0
        ua = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
        return inter / max(ua, 1e-9)

    proposals.sort(key=lambda item: item[1], reverse=True)
    kept: list[tuple[list[float], float]] = []
    for box, sc in proposals:
        if any(box_iou(box, kb) > 0.50 for kb, _ in kept):
            continue
        kept.append((box, sc))
        if len(kept) >= 6:
            break

    if not kept and float(scene_prob[0]) >= thresholds.scene_prob_floor * 0.4:
        kept.append(([0.0, 0.0, 1.0, 1.0], float(scene_prob[0])))
    elif len(kept) == 1 and float(scene_prob[1]) < 0.40:
        kept.append(([0.0, 0.0, 1.0, 1.0], float(scene_prob[0]) * 0.85))

    return kept


def _subpixel_at_cell(hm: np.ndarray, corner_offsets: np.ndarray, px: int, py: int) -> tuple[float, float]:
    grid = hm.shape[0]
    peak_val = float(hm[py, px])
    x_sum = 0.0
    y_sum = 0.0
    w_sum = 0.0
    thresh = max(0.05, peak_val * 0.35)
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            nx, ny = px + dx, py + dy
            if 0 <= nx < grid and 0 <= ny < grid:
                v = float(hm[ny, nx])
                if v >= thresh:
                    w = v * v
                    x_sum += w * nx
                    y_sum += w * ny
                    w_sum += w
    sub_x = (x_sum / w_sum) if w_sum > 1e-8 else float(px)
    sub_y = (y_sum / w_sum) if w_sum > 1e-8 else float(py)
    off_x = float(corner_offsets[0, py, px])
    off_y = float(corner_offsets[1, py, px])
    u = float(np.clip((0.55 * (px + 0.5 + off_x) + 0.45 * (sub_x + 0.5)) / grid, 0.0, 1.0))
    v = float(np.clip((0.55 * (py + 0.5 + off_y) + 0.45 * (sub_y + 0.5)) / grid, 0.0, 1.0))
    return u, v


def _edge_support_for_quad(edge_map: np.ndarray, corners_roi: np.ndarray) -> list[float]:
    grid = edge_map.shape[0]
    edge_supports: list[float] = []
    n_samples = 24
    for s_idx in range(4):
        p1 = corners_roi[s_idx] * (grid - 1)
        p2 = corners_roi[(s_idx + 1) % 4] * (grid - 1)
        acc = 0.0
        for k in range(1, n_samples - 1):
            t = k / (n_samples - 1)
            sx = int(round(float(p1[0] + (p2[0] - p1[0]) * t)))
            sy = int(round(float(p1[1] + (p2[1] - p1[1]) * t)))
            y0, y1 = max(0, sy - 1), min(grid, sy + 2)
            x0, x1 = max(0, sx - 1), min(grid, sx + 2)
            acc += float(edge_map[y0:y1, x0:x1].max())
        edge_supports.append(acc / (n_samples - 2))
    return edge_supports


def decode_stage2_roi(
    corner_heatmaps: np.ndarray,
    corner_offsets: np.ndarray,
    roi_quality: np.ndarray,
    rx0: float,
    ry0: float,
    rx1: float,
    ry1: float,
) -> tuple[np.ndarray, list[float], list[float], list[float]]:
    """Decode Stage-2 [6, 64, 64] + [2, 64, 64] + [3] using ordered channels (0..3),
    union corner peaks, and neural perimeter boundary_edge (ch 5)."""
    grid = corner_heatmaps.shape[1]
    union_hm = np.max(corner_heatmaps[0:5], axis=0)
    edge_map = corner_heatmaps[5]

    candidates_roi: list[tuple[float, np.ndarray, list[float], list[float]]] = []

    is_full_roi = (rx1 - rx0) >= 0.95 and (ry1 - ry0) >= 0.95
    min_roi_area = 0.015 if is_full_roi else 0.14

    def score_roi_candidate(
        q_c: np.ndarray, p_c: list[float], e_c: list[float]
    ) -> float | None:
        issues_c, area_c, geom_c = assess_quad_domain(q_c, 256, 256, min_area_fraction=min_roi_area)
        if issues_c:
            return None
        area_bonus = 0.0 if is_full_roi else 0.45 * min(1.0, area_c / 0.38)
        return (
            0.85 * min(p_c)
            + 0.45 * (sum(p_c) / 4.0)
            + 0.75 * min(e_c)
            + 0.65 * (sum(e_c) / 4.0)
            + 0.25 * geom_c
            + area_bonus
        )

    # Candidate A: Greedy distinct-cell assignment across ordered channels 0..3
    quad_a = np.zeros((4, 2), dtype=np.float32)
    peaks_a: list[float] = []
    chosen_cells: list[tuple[int, int]] = []
    for c_idx in range(4):
        hm_c = corner_heatmaps[c_idx].copy()
        for ox, oy in chosen_cells:
            y0, y1 = max(0, oy - 4), min(grid, oy + 5)
            x0, x1 = max(0, ox - 4), min(grid, ox + 5)
            hm_c[y0:y1, x0:x1] = -1.0
        flat_idx = int(np.argmax(hm_c))
        py, px = divmod(flat_idx, grid)
        chosen_cells.append((px, py))
        peaks_a.append(float(max(corner_heatmaps[c_idx, py, px], union_hm[py, px] * 0.95)))
        u, v = _subpixel_at_cell(union_hm, corner_offsets, px, py)
        quad_a[c_idx, 0] = u
        quad_a[c_idx, 1] = v
    quad_a = canonicalize_quad_clockwise_tl(quad_a)
    edges_a = _edge_support_for_quad(edge_map, quad_a)
    sc_a = score_roi_candidate(quad_a, peaks_a, edges_a)
    if sc_a is not None:
        candidates_roi.append((sc_a, quad_a, peaks_a, edges_a))

    # Candidate B: Top-8 distinct local maxima on union_hm
    local_peaks: list[tuple[float, int, int]] = []
    for py in range(grid):
        for px in range(grid):
            val = float(union_hm[py, px])
            if val < 0.14:
                continue
            y0, y1 = max(0, py - 2), min(grid, py + 3)
            x0, x1 = max(0, px - 2), min(grid, px + 3)
            if val >= float(union_hm[y0:y1, x0:x1].max()):
                local_peaks.append((val, px, py))

    local_peaks.sort(key=lambda t: t[0], reverse=True)
    distinct_peaks: list[tuple[float, int, int]] = []
    for val, px, py in local_peaks:
        if any((px - ox) ** 2 + (py - oy) ** 2 < 25 for _, ox, oy in distinct_peaks):
            continue
        distinct_peaks.append((val, px, py))
        if len(distinct_peaks) >= 8:
            break

    if len(distinct_peaks) >= 4:
        pts_sub = [(_subpixel_at_cell(union_hm, corner_offsets, px, py), val) for val, px, py in distinct_peaks]
        for comb in combinations(range(len(pts_sub)), 4):
            q_raw = np.array([pts_sub[i][0] for i in comb], dtype=np.float32)
            q_cand = canonicalize_quad_clockwise_tl(q_raw)
            p_cand = [pts_sub[i][1] for i in comb]
            e_cand = _edge_support_for_quad(edge_map, q_cand)
            sc_b = score_roi_candidate(q_cand, p_cand, e_cand)
            if sc_b is not None:
                candidates_roi.append((sc_b, q_cand, p_cand, e_cand))

    if candidates_roi:
        candidates_roi.sort(key=lambda item: item[0], reverse=True)
        _, best_quad, best_peaks, best_edges = candidates_roi[0]
    else:
        best_quad, best_peaks, best_edges = quad_a, peaks_a, edges_a

    full_corners = np.zeros((4, 2), dtype=np.float32)
    full_corners[:, 0] = rx0 + best_quad[:, 0] * (rx1 - rx0)
    full_corners[:, 1] = ry0 + best_quad[:, 1] * (ry1 - ry0)
    full_corners = canonicalize_quad_clockwise_tl(np.clip(full_corners, 0.0, 1.0))
    quals = [float(roi_quality[0]), float(roi_quality[1]), float(roi_quality[2])]
    return full_corners, best_peaks, best_edges, quals


def refine_quad_edges_locally(
    rgb: np.ndarray,
    quad_norm: np.ndarray,
    max_shift_norm: float = 0.014,
) -> np.ndarray:
    """Tight physical contrast-step line refinement within ±1.4% corridor on preview raster."""
    h, w = rgb.shape[:2]
    if min(h, w) < 80:
        return quad_norm
    luma = (
        0.299 * rgb[:, :, 0].astype(np.float32)
        + 0.587 * rgb[:, :, 1].astype(np.float32)
        + 0.114 * rgb[:, :, 2].astype(np.float32)
    )
    scale = np.array([w - 1.0, h - 1.0], dtype=np.float64)
    pts_px = quad_norm.astype(np.float64) * scale
    max_r = max(2, min(14, int(round(min(w, h) * max_shift_norm))))

    refined_lines: list[tuple[np.ndarray, np.ndarray]] = []
    for i in range(4):
        p1 = pts_px[i]
        p2 = pts_px[(i + 1) % 4]
        vec = p2 - p1
        length = float(np.linalg.norm(vec))
        if length < 16.0:
            return quad_norm
        tangent = vec / length
        normal = np.array([-tangent[1], tangent[0]], dtype=np.float64)

        n_stat = 20
        offsets = np.arange(-max_r, max_r + 1, dtype=np.float64)
        grad_profile = np.zeros_like(offsets)
        valid_stat = 0
        for s in range(n_stat):
            t = 0.15 + 0.70 * (s / (n_stat - 1))
            base = p1 + tangent * (length * t)
            xs = base[0] + normal[0] * offsets
            ys = base[1] + normal[1] * offsets
            if xs.min() < 1 or xs.max() >= w - 2 or ys.min() < 1 or ys.max() >= h - 2:
                continue
            xi = np.round(xs).astype(np.int32)
            yi = np.round(ys).astype(np.int32)
            vals = luma[yi, xi]
            if len(vals) >= 5:
                step = np.abs(vals[2:] - vals[:-2])
                grad_profile[1:-1] += step
                valid_stat += 1

        if valid_stat >= 10:
            grad_profile /= valid_stat
            best_idx = int(np.argmax(grad_profile))
            best_grad = float(grad_profile[best_idx])
            median_grad = float(np.median(grad_profile))
            if best_grad >= 14.0 and best_grad >= median_grad * 1.85:
                shift = float(offsets[best_idx]) * normal
                refined_lines.append((p1 + shift, tangent))
            else:
                refined_lines.append((p1, tangent))
        else:
            refined_lines.append((p1, tangent))

    new_pts = np.zeros((4, 2), dtype=np.float64)
    for i in range(4):
        p_prev, d_prev = refined_lines[(i + 3) % 4]
        p_curr, d_curr = refined_lines[i]
        denom = float(d_prev[0] * d_curr[1] - d_prev[1] * d_curr[0])
        if abs(denom) < 1e-6:
            return quad_norm
        diff = p_curr - p_prev
        t_val = float((diff[0] * d_curr[1] - diff[1] * d_curr[0]) / denom)
        new_pts[i] = p_prev + d_prev * t_val

    new_norm = (new_pts / scale).astype(np.float32)
    if np.any(new_norm < 0.0) or np.any(new_norm > 1.0):
        return quad_norm
    max_move = float(np.max(np.linalg.norm(new_norm - quad_norm, axis=1)))
    if max_move > max_shift_norm * 1.6:
        return quad_norm
    issues, _, _ = assess_quad_domain(new_norm, w, h)
    if issues:
        return quad_norm
    return canonicalize_quad_clockwise_tl(new_norm)


def classify_candidate_verdict(
    cand: AiQuadCandidate,
    thresholds: FrozenThresholds,
    expected_aspect: float | None = None,
    source_w: int = 1000,
    source_h: int = 1000,
) -> tuple[Verdict, list[str]]:
    if (
        cand.roi_valid_prob < thresholds.review_roi_valid
        or cand.min_corner_peak < thresholds.review_min_corner_peak
        or cand.mean_corner_peak < thresholds.review_mean_corner_peak
        or cand.mean_edge_support < thresholds.review_mean_edge_support
    ):
        return "rejected", ["lowConfidence"]

    reasons: list[str] = []
    is_accept = (
        cand.roi_valid_prob >= thresholds.accept_roi_valid
        and cand.four_visible_prob >= thresholds.accept_four_visible
        and cand.min_corner_peak >= thresholds.accept_min_corner_peak
        and cand.mean_corner_peak >= thresholds.accept_mean_corner_peak
        and cand.min_edge_support >= thresholds.accept_min_edge_support
        and cand.mean_edge_support >= thresholds.accept_mean_edge_support
        and cand.frame_touch_count == 0
        and cand.confidence >= 0.55
    )
    if not is_accept:
        reasons.append("lowConfidence")
    if cand.frame_touch_count > 0:
        is_accept = False
        if "touchesFrameEdge" not in reasons:
            reasons.append("touchesFrameEdge")

    if expected_aspect is not None and expected_aspect > 0:
        px = cand.corners * np.array([max(1, source_w - 1), max(1, source_h - 1)], dtype=np.float64)
        s0 = float(np.linalg.norm(px[1] - px[0]))
        s1_l = float(np.linalg.norm(px[2] - px[1]))
        s2_l = float(np.linalg.norm(px[3] - px[2]))
        s3_l = float(np.linalg.norm(px[0] - px[3]))
        mw, mh = 0.5 * (s0 + s2_l), 0.5 * (s1_l + s3_l)
        meas_asp = max(mw, mh) / max(1e-6, min(mw, mh))
        exp_norm = max(expected_aspect, 1.0 / expected_aspect)
        rel_diff = abs(meas_asp - exp_norm) / exp_norm
        if rel_diff > 0.35:
            return "rejected", ["aspectMismatch"]
        if rel_diff > 0.18:
            is_accept = False
            reasons.append("aspectMismatch")

    return ("accepted" if is_accept else "needsReview"), reasons


class TwoStageOnnxDetector:
    def __init__(
        self,
        stage1_onnx_path: str,
        stage2_onnx_path: str,
        thresholds: FrozenThresholds | None = None,
    ) -> None:
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 1
        opts.inter_op_num_threads = 1
        self.s1 = ort.InferenceSession(stage1_onnx_path, sess_options=opts, providers=["CPUExecutionProvider"])
        self.s2 = ort.InferenceSession(stage2_onnx_path, sess_options=opts, providers=["CPUExecutionProvider"])
        self.thresholds = thresholds or FrozenThresholds()

    def detect(
        self,
        rgb: np.ndarray,
        expected_aspect: float | None = None,
    ) -> AiDetectionResult:
        h, w = rgb.shape[:2]
        if w < 32 or h < 32:
            return AiDetectionResult(0.0, 0.0, False, [])

        inp1 = bilinear_resize_rgb_to_chw(rgb, 160, 160)
        dense_map, scene_prob = self.s1.run(None, {"input": inp1})
        dense = dense_map[0]
        sc_prob = scene_prob[0]
        has_doc_p = float(sc_prob[0])
        multi_p = float(sc_prob[1])

        proposals = extract_stage1_proposals(dense, sc_prob, self.thresholds)
        raw_candidates: list[AiQuadCandidate] = []

        for coarse_box, _ in proposals:
            xmin, ymin, xmax, ymax = coarse_box
            bw, bh = xmax - xmin, ymax - ymin
            if bw >= 0.96 and bh >= 0.96:
                rx0, ry0, rx1, ry1 = 0.0, 0.0, 1.0, 1.0
            else:
                rx0 = max(0.0, xmin - bw * 0.22)
                ry0 = max(0.0, ymin - bh * 0.22)
                rx1 = min(1.0, xmax + bw * 0.22)
                ry1 = min(1.0, ymax + bh * 0.22)
            if rx1 - rx0 < 0.08 or ry1 - ry0 < 0.08:
                continue

            inp2 = bilinear_resize_rgb_to_chw(rgb, 128, 128, rx0, ry0, rx1, ry1)
            c_hmaps, c_offs, r_qual = self.s2.run(None, {"input": inp2})
            full_q, peaks, edges, quals = decode_stage2_roi(
                c_hmaps[0], c_offs[0], r_qual[0], rx0, ry0, rx1, ry1
            )

            issues, area_frac, geom_conf = assess_quad_domain(full_q, w, h)
            if issues or area_frac >= 0.94:
                continue

            snapped_q = refine_quad_edges_locally(rgb, full_q)
            issues2, area_frac2, geom_conf2 = assess_quad_domain(snapped_q, w, h)
            if not issues2 and area_frac2 < 0.94:
                full_q = snapped_q
                geom_conf = geom_conf2

            min_cp = min(peaks)
            mean_cp = sum(peaks) / 4.0
            min_es = min(edges)
            mean_es = sum(edges) / 4.0
            touches = count_frame_touches(full_q, edges)
            structural_complete = min(min_cp, min_es) * 0.95 if touches == 0 else 0.0
            roi_valid = max(quals[0], structural_complete)
            four_vis = max(quals[1], structural_complete)

            neural_conf = (
                0.30 * roi_valid
                + 0.15 * four_vis
                + 0.25 * mean_cp
                + 0.15 * min_cp
                + 0.15 * mean_es
            )
            combined_conf = min(geom_conf, neural_conf)
            reg = [
                float(full_q[:, 0].min()),
                float(full_q[:, 1].min()),
                float(full_q[:, 0].max()),
                float(full_q[:, 1].max()),
            ]
            cand = AiQuadCandidate(
                corners=full_q,
                region=reg,
                confidence=float(combined_conf),
                geom_confidence=float(geom_conf),
                roi_valid_prob=roi_valid,
                four_visible_prob=four_vis,
                min_corner_peak=min_cp,
                mean_corner_peak=mean_cp,
                min_edge_support=min_es,
                mean_edge_support=mean_es,
                frame_touch_count=touches,
                verdict="needsReview",
                reasons=[],
            )
            verdict, reasons = classify_candidate_verdict(cand, self.thresholds, expected_aspect, w, h)
            if verdict == "rejected":
                continue
            cand.verdict = verdict
            cand.reasons = reasons
            raw_candidates.append(cand)

        raw_candidates.sort(
            key=lambda c: 0.55 * c.confidence + 0.45 * c.mean_edge_support,
            reverse=True,
        )
        kept: list[AiQuadCandidate] = []
        for cand in raw_candidates:
            duplicate = False
            for idx_p, prev in enumerate(kept):
                iou_pair = polygon_iou(cand.corners, prev.corners)
                inter_a = polygon_area(clip_convex_polygon(cand.corners, prev.corners))
                area_c = polygon_area(cand.corners)
                area_p = polygon_area(prev.corners)
                min_a = min(area_c, area_p)
                containment = (inter_a / min_a) if min_a > 1e-6 else 0.0
                if iou_pair > self.thresholds.nms_polygon_iou or containment > 0.65:
                    if (
                        area_c >= 1.45 * area_p
                        and (inter_a / max(1e-6, area_p)) >= 0.78
                        and cand.mean_edge_support >= 0.72
                        and cand.roi_valid_prob >= 0.80
                    ):
                        kept[idx_p] = cand
                    elif (
                        prev.verdict == "accepted"
                        and iou_pair < 0.80
                        and cand.mean_edge_support > prev.mean_edge_support + 0.08
                    ):
                        prev.verdict = "needsReview"
                        if "lowConfidence" not in prev.reasons:
                            prev.reasons.append("lowConfidence")
                    duplicate = True
                    break
            if not duplicate:
                kept.append(cand)

        kept.sort(key=lambda c: (round(c.region[1] * 10), -c.region[0]))
        return AiDetectionResult(
            scene_has_doc_prob=has_doc_p,
            scene_multi_prob=multi_p,
            multi=len(kept) >= 2,
            candidates=kept,
        )
