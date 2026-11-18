#!/usr/bin/env python3
"""Propose card quadrilaterals, refine them, and score each one by the
completeness of its rectified crop.

Why scoring the warp matters: a boundary is only correct if the rectified crop
contains the whole document and nothing else. A 15 px error on a diagonal is
nearly invisible on an overlay but immediately obvious in the warp, because the
crop gains a band of table or loses a strip of the card. So the score used here
is measured on the warp itself:

  edge_score  = mean gradient magnitude in a 3 px ring just inside the warp
                border, divided by the mean gradient magnitude of the warp
                interior. A complete, correctly cut card has a quiet border
                (its own margin) and a busy interior (its text), so the ratio
                is small. A crop that includes table or cuts the card has a
                strong ridge on the border, so the ratio rises toward 1.

Candidates come from three independent classical sources, so a card missed by
one is usually found by another:

  A. global background-distance mask + Otsu + components (+ neck splitting),
  B. per-channel adaptive threshold components,
  C. Canny contour quadrilaterals.

Every proposal is refined by snapping each side onto the strongest nearby
gradient ridge and then scored. Output keeps at most `--per-image` distinct
quads per image, each with its measured score and the source that produced it.

Nothing here is ground truth; the flag stays `"verified": false`.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np

MIN_AREA = 0.010
MAX_AREA = 0.95
CARD_ASPECT = (1.10, 2.60)
WARP_LONG = 420


def _load(path: Path):
    data = np.fromfile(str(path), dtype=np.uint8)
    image = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if image is None:
        raise SystemExit(f"cannot decode {path.name}")
    return image


def _order(quad) -> np.ndarray:
    pts = np.asarray(quad, dtype=np.float64).reshape(4, 2)
    centre = pts.mean(axis=0)
    angles = np.arctan2(pts[:, 1] - centre[1], pts[:, 0] - centre[0])
    ring = pts[np.argsort(angles)]
    start = int(np.argmin([p[0] + p[1] for p in ring]))
    return np.roll(ring, -start, axis=0)


def _iou(a, b) -> float:
    inter, _ = cv2.intersectConvexConvex(
        np.asarray(a, np.float32), np.asarray(b, np.float32)
    )
    ua = abs(cv2.contourArea(np.asarray(a, np.float32)))
    ub = abs(cv2.contourArea(np.asarray(b, np.float32)))
    union = ua + ub - inter
    return float(inter / union) if union > 0 else 0.0


# ---------------------------------------------------------------- proposals


def _component_quads(image) -> list[np.ndarray]:
    height, width = image.shape[:2]
    scale = min(1.0, 640 / max(width, height))
    work = (
        cv2.resize(image, (int(width * scale), int(height * scale)),
                   interpolation=cv2.INTER_AREA)
        if scale < 1.0
        else image
    )
    h, w = work.shape[:2]
    total = float(w * h)
    out: list[np.ndarray] = []

    lab = cv2.cvtColor(work, cv2.COLOR_BGR2LAB).astype(np.int16)
    border = np.concatenate(
        [
            lab[:2].reshape(-1, 3),
            lab[-2:].reshape(-1, 3),
            lab[:, :2].reshape(-1, 3),
            lab[:, -2:].reshape(-1, 3),
        ]
    )
    background = np.median(border, axis=0)
    distance = np.abs(lab - background).sum(axis=2).astype(np.float32)
    flat = distance.reshape(-1).astype(np.uint8)
    threshold, _ = cv2.threshold(flat, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    for bias in (0.75, 1.0, 1.3):
        limit = float(np.clip(threshold * bias, 4, 254))
        mask = (
            (distance > limit).astype(np.uint8) * 255
        )
        mask = cv2.morphologyEx(
            mask, cv2.MORPH_CLOSE, np.ones((7, 7), np.uint8), iterations=2
        )
        mask = cv2.morphologyEx(
            mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8), iterations=1
        )
        count, labels, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
        for index in range(1, count):
            area = float(stats[index, cv2.CC_STAT_AREA])
            if not MIN_AREA * total <= area <= MAX_AREA * total:
                continue
            component = (labels == index).astype(np.uint8)
            out.extend(_component_quad(component, h, w, area / total))
    return _rescale(out, scale)


def _rescale(quads, scale):
    """Work-frame quads are proposals in work pixels; the caller scores and
    reports them in ORIGINAL image pixels."""
    if scale >= 1.0:
        return quads
    return [np.asarray(quad, np.float64) / scale for quad in quads]


def _component_quad(component, h, w, fraction) -> list[np.ndarray]:
    """One-to-two quads for a mask component, splitting a bridged pair."""
    quads: list[np.ndarray] = []
    for mask in _split_mask(component, h, w):
        contours, _ = cv2.findContours(
            mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
        )
        if not contours:
            continue
        contour = max(contours, key=cv2.contourArea)
        area = cv2.contourArea(contour)
        if area < MIN_AREA * (h * w):
            continue
        box = _order(cv2.boxPoints(cv2.minAreaRect(contour)))
        sides = [float(np.linalg.norm(box[(i + 1) % 4] - box[i])) for i in range(4)]
        aspect = max(sides) / max(1e-6, min(sides))
        if CARD_ASPECT[0] <= aspect <= CARD_ASPECT[1]:
            quads.append(box)
    return quads


def _split_mask(mask, h, w) -> list[np.ndarray]:
    """Split a component whose row or column occupancy has a clear neck."""
    ys, xs = np.nonzero(mask)
    if len(xs) < 50:
        return [mask]
    left, right = int(xs.min()), int(xs.max())
    top, bottom = int(ys.min()), int(ys.max())
    for axis in (0, 1):
        span = (right - left + 1) if axis == 0 else (bottom - top + 1)
        if span < 40:
            continue
        counts = np.zeros(span, dtype=np.int64)
        sub = mask[top : bottom + 1, left : right + 1]
        if axis == 0:
            counts = sub.sum(axis=0) // 255
            cross = sub.shape[0]
        else:
            counts = sub.sum(axis=1) // 255
            cross = sub.shape[1]
        low, high = int(0.22 * span), int(0.78 * span)
        if high <= low + 4:
            continue
        window = counts[low:high]
        valley = int(low + np.argmin(window))
        peak_left = int(counts[:valley].max()) if valley > 0 else 0
        peak_right = int(counts[valley + 1 :].max()) if valley + 1 < span else 0
        if peak_left == 0 or peak_right == 0:
            continue
        min_peak = min(peak_left, peak_right) / max(1, cross)
        valley_ratio = counts[valley] / max(1, cross)
        if min_peak >= 0.55 and valley_ratio < 0.62 * min_peak:
            first = sub.copy()
            second = sub.copy()
            if axis == 0:
                first[:, valley:] = 0
                second[:, : valley + 1] = 0
            else:
                first[valley:, :] = 0
                second[: valley + 1, :] = 0
            parts = []
            for piece in (first, second):
                filled = np.zeros_like(mask)
                filled[top : bottom + 1, left : right + 1] = piece
                parts.extend(_split_mask(filled, h, w) if piece.any() else [])
            return parts
    return [mask]


def _adaptive_quads(image) -> list[np.ndarray]:
    height, width = image.shape[:2]
    scale = min(1.0, 640 / max(width, height))
    work = (
        cv2.resize(image, (int(width * scale), int(height * scale)),
                   interpolation=cv2.INTER_AREA)
        if scale < 1.0
        else image
    )
    h, w = work.shape[:2]
    total = float(w * h)
    lab = cv2.cvtColor(work, cv2.COLOR_BGR2LAB)
    out: list[np.ndarray] = []
    for channel in cv2.split(lab):
        blur = cv2.GaussianBlur(channel, (7, 7), 0)
        for polarity in (cv2.THRESH_BINARY, cv2.THRESH_BINARY_INV):
            for block in (41, 81):
                binary = cv2.adaptiveThreshold(
                    blur, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, polarity, block, -5
                )
                cleaned = cv2.morphologyEx(
                    binary, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8), iterations=2
                )
                count, labels, stats, _ = cv2.connectedComponentsWithStats(
                    cleaned, 8
                )
                for index in range(1, count):
                    area = float(stats[index, cv2.CC_STAT_AREA])
                    if not MIN_AREA * total <= area <= MAX_AREA * total:
                        continue
                    component = (labels == index).astype(np.uint8)
                    out.extend(_component_quad(component, h, w, area / total))
    return _rescale(out, scale)


def _contour_quads(image) -> list[np.ndarray]:
    height, width = image.shape[:2]
    scale = min(1.0, 900 / max(width, height))
    work = (
        cv2.resize(image, (int(width * scale), int(height * scale)),
                   interpolation=cv2.INTER_AREA)
        if scale < 1.0
        else image
    )
    h, w = work.shape[:2]
    total = float(w * h)
    grey = cv2.bilateralFilter(cv2.cvtColor(work, cv2.COLOR_BGR2GRAY), 9, 70, 70)
    out: list[np.ndarray] = []
    for low, high in ((25, 80), (50, 140), (90, 200)):
        edges = cv2.Canny(grey, low, high)
        edges = cv2.morphologyEx(
            edges, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8), iterations=2
        )
        contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        for contour in sorted(contours, key=cv2.contourArea, reverse=True)[:60]:
            area = cv2.contourArea(contour)
            if not MIN_AREA * total <= area / 1.0 <= MAX_AREA * total:
                continue
            perimeter = cv2.arcLength(contour, True)
            for epsilon in (0.015, 0.025, 0.04, 0.06):
                approx = cv2.approxPolyDP(contour, epsilon * perimeter, True)
                if len(approx) != 4 or not cv2.isContourConvex(approx):
                    continue
                quad = _order(approx.reshape(4, 2))
                sides = [
                    float(np.linalg.norm(quad[(i + 1) % 4] - quad[i]))
                    for i in range(4)
                ]
                if min(sides) < 25:
                    break
                if CARD_ASPECT[0] <= max(sides) / min(sides) <= CARD_ASPECT[1]:
                    out.append(quad)
                break
    return _rescale(out, scale)


# ---------------------------------------------------------------- refinement


def _refine(image, quad_px, search_px=12):
    grey = cv2.GaussianBlur(cv2.cvtColor(image, cv2.COLOR_BGR2GRAY).astype(np.float32), (5, 5), 0)
    gx = cv2.Sobel(grey, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(grey, cv2.CV_32F, 0, 1, ksize=3)
    magnitude = cv2.magnitude(gx, gy)
    height, width = grey.shape[:2]
    lines = []
    for index in range(4):
        a = np.asarray(quad_px[index], np.float64)
        b = np.asarray(quad_px[(index + 1) % 4], np.float64)
        direction = b - a
        length = float(np.linalg.norm(direction))
        if length < 12:
            lines.append(None)
            continue
        unit = direction / length
        normal = np.array([-unit[1], unit[0]])
        samples = []
        for t in np.linspace(0.10, 0.90, 72):
            base = a + direction * t
            best_value, best_point = 0.0, None
            for offset in np.arange(-search_px, search_px + 0.5, 1.0):
                point = base + normal * offset
                x, y = int(round(point[0])), int(round(point[1]))
                if not (0 <= x < width and 0 <= y < height):
                    continue
                value = float(magnitude[y, x])
                if value > best_value:
                    best_value, best_point = value, point
            if best_point is not None and best_value > 25.0:
                samples.append(best_point)
        if len(samples) < 14:
            lines.append((a, b))
            continue
        points = np.array(samples)
        centred = points - points.mean(axis=0)
        _, _, vh = np.linalg.svd(centred, full_matrices=False)
        direction_fit = vh[0]
        mean = points.mean(axis=0)
        lines.append((mean - direction_fit * 10, mean + direction_fit * 10))

    def intersect(l1, l2):
        p = np.asarray(l1[0], np.float64)
        r = np.asarray(l1[1], np.float64) - p
        q = np.asarray(l2[0], np.float64)
        s = np.asarray(l2[1], np.float64) - q
        cross = r[0] * s[1] - r[1] * s[0]
        if abs(cross) < 1e-9:
            return None
        t = ((q[0] - p[0]) * s[1] - (q[1] - p[1]) * s[0]) / cross
        return p + r * t

    refined = []
    for index in range(4):
        previous, current = lines[(index - 1) % 4], lines[index]
        point = intersect(previous, current) if previous and current else None
        refined.append(
            np.asarray(quad_px[index], np.float64)
            if point is None or not np.all(np.isfinite(point))
            else point
        )
    refined = _order(np.array(refined))
    if np.max(np.linalg.norm(refined - np.asarray(quad_px, np.float64), axis=1)) > (
        0.05 * max(width, height)
    ):
        return _order(np.asarray(quad_px, np.float64))
    return refined


def _warp(image, quad_px):
    width = int(
        max(
            np.linalg.norm(quad_px[1] - quad_px[0]),
            np.linalg.norm(quad_px[2] - quad_px[3]),
        )
    )
    height = int(
        max(
            np.linalg.norm(quad_px[3] - quad_px[0]),
            np.linalg.norm(quad_px[2] - quad_px[1]),
        )
    )
    width, height = max(3, width), max(3, height)
    destination = np.array(
        [[0, 0], [width - 1, 0], [width - 1, height - 1], [0, height - 1]],
        np.float32,
    )
    matrix = cv2.getPerspectiveTransform(quad_px.astype(np.float32), destination)
    return cv2.warpPerspective(image, matrix, (width, height))


def _border_score(warp) -> float:
    """Quiet border, busy interior => complete crop. Lower is better."""
    grey = cv2.cvtColor(warp, cv2.COLOR_BGR2GRAY).astype(np.float32)
    gx = cv2.Sobel(grey, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(grey, cv2.CV_32F, 0, 1, ksize=3)
    magnitude = cv2.magnitude(gx, gy)
    height, width = magnitude.shape[:2]
    if height < 12 or width < 12:
        return 9.0
    ring = 3
    inner = magnitude[ring : height - ring, ring : width - ring]
    if inner.size == 0:
        return 9.0
    mask = np.ones_like(magnitude, dtype=bool)
    mask[ring : height - ring, ring : width - ring] = False
    border_values = magnitude[mask]
    interior = float(np.mean(inner))
    border = float(np.mean(border_values))
    if interior <= 1e-3:
        return min(9.0, 1.0 + border / 8.0)
    return float(border / interior)


def _coverage(warp) -> float:
    """Fraction of the warp that is not near-uniform background."""
    grey = cv2.cvtColor(warp, cv2.COLOR_BGR2GRAY)
    return float(np.std(grey) / 64.0)


def score_quad(image, quad_px) -> tuple[float, dict]:
    warp = _warp(image, quad_px)
    scale = WARP_LONG / max(warp.shape[:2])
    if scale < 1.0:
        warp = cv2.resize(
            warp,
            (max(1, int(warp.shape[1] * scale)), max(1, int(warp.shape[0] * scale))),
            interpolation=cv2.INTER_AREA,
        )
    border = _border_score(warp)
    coverage = _coverage(warp)
    # A complete crop: quiet border and real content inside.
    score = border + max(0.0, 0.25 - coverage) * 4.0
    return score, {"border_ratio": round(border, 4), "coverage": round(coverage, 4)}


def propose_for_image(image, per_image: int = 6) -> list[dict]:
    height, width = image.shape[:2]
    pool: list[tuple[str, np.ndarray]] = []
    for name, provider in (
        ("component", _component_quads),
        ("adaptive", _adaptive_quads),
        ("contour", _contour_quads),
    ):
        try:
            for quad in provider(image):
                pool.append((name, quad))
        except Exception:  # noqa: BLE001 - a bad parameter set must not stop
            continue
    # Deduplicate on the draft geometry before the expensive refinement.
    unique: list[tuple[str, np.ndarray]] = []
    for name, quad in pool:
        if any(_iou(quad, other) > 0.55 for _, other in unique):
            continue
        unique.append((name, quad))
    scored = []
    for name, quad in unique:
        refined = _refine(image, quad)
        score, metrics = score_quad(image, refined)
        scored.append((score, name, refined, metrics))
    scored.sort(key=lambda item: item[0])
    kept = []
    for score, name, quad, metrics in scored:
        if any(_iou(quad, other) > 0.55 for _, _, other, _ in kept):
            continue
        kept.append((score, name, quad, metrics))
        if len(kept) >= per_image:
            break
    out = []
    for position, (score, name, quad, metrics) in enumerate(kept, start=1):
        out.append(
            {
                "instance": position,
                "points_norm": [
                    [
                        round(float(x) / max(1, width - 1), 6),
                        round(float(y) / max(1, height - 1), 6),
                    ]
                    for x, y in quad
                ],
                "source": f"auto-propose:{name}",
                "verified": False,
                "score": round(float(score), 4),
                **metrics,
            }
        )
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--per-image", type=int, default=6)
    parser.add_argument("--report", type=Path, default=None)
    args = parser.parse_args()
    images = sorted(
        p for p in (args.dataset / "images_original").iterdir() if p.is_file()
    )
    proposals = []
    report = {}
    for index, path in enumerate(images, start=1):
        image = _load(path)
        entries = propose_for_image(image, args.per_image)
        for entry in entries:
            entry["image_index"] = index
            entry["filename"] = path.name
        proposals.extend(entries)
        report[f"image_{index:03d}"] = [
            {
                "instance": entry["instance"],
                "score": entry["score"],
                "border_ratio": entry["border_ratio"],
                "coverage": entry["coverage"],
                "source": entry["source"],
            }
            for entry in entries
        ]
    args.out.write_text(
        json.dumps(proposals, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    if args.report:
        args.report.write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    print(
        json.dumps(
            {
                "images": len(images),
                "quads": len(proposals),
                "images_with_quads": len({e["image_index"] for e in proposals}),
                "images_without_quads": [
                    index
                    for index in range(1, len(images) + 1)
                    if index not in {e["image_index"] for e in proposals}
                ],
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
