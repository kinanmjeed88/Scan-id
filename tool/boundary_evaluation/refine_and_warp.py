#!/usr/bin/env python3
"""Refine draft quadrilaterals against the original pixels and render the
rectified crop for human verification.

A quadrilateral is only accepted as ground truth when the *rectified crop*
looks like the complete document: no background band, no cut edge. Reviewing
the warp is a far stronger check than looking at a thin overlay line, because
a corner that is off by a few percent is immediately visible in the output.

This tool produces review material only. It writes quads into
`reviewed_candidates.json` with `verified: false`; the reviewer flips the flag
after looking at the crop, per the annotation protocol.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np

TARGET_LONG_EDGE = 520


def _load(path: Path):
    data = np.fromfile(str(path), dtype=np.uint8)
    image = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if image is None:
        raise SystemExit(f"cannot decode {path.name}")
    return image


def _order(quad: np.ndarray) -> np.ndarray:
    pts = np.asarray(quad, dtype=np.float64).reshape(4, 2)
    centre = pts.mean(axis=0)
    angles = np.arctan2(pts[:, 1] - centre[1], pts[:, 0] - centre[0])
    ring = pts[np.argsort(angles)]
    start = int(np.argmin([p[0] + p[1] for p in ring]))
    return np.roll(ring, -start, axis=0)


def _to_pixels(quad_norm, width: int, height: int) -> np.ndarray:
    return np.array(
        [
            [
                min(max(float(x), 0.0), 1.0) * (width - 1),
                min(max(float(y), 0.0), 1.0) * (height - 1),
            ]
            for x, y in quad_norm
        ],
        dtype=np.float64,
    )


def _refine(image, quad_px: np.ndarray, search_px: int = 14) -> np.ndarray:
    """Snap each side onto the strongest nearby gradient ridge.

    For every side, sample points along the current line, look for the
    maximum gradient magnitude along the side normal within +/- search_px,
    and refit a line by least squares on the accepted samples. Corners are the
    intersections of consecutive fitted lines. A side whose ridge support is
    weak keeps the drafted line, so refinement never invents an edge.
    """
    grey = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY).astype(np.float32)
    grey = cv2.GaussianBlur(grey, (5, 5), 0)
    gx = cv2.Sobel(grey, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(grey, cv2.CV_32F, 0, 1, ksize=3)
    magnitude = cv2.magnitude(gx, gy)
    height, width = grey.shape[:2]

    lines = []
    for index in range(4):
        a = quad_px[index]
        b = quad_px[(index + 1) % 4]
        direction = b - a
        length = float(np.linalg.norm(direction))
        if length < 8:
            lines.append(None)
            continue
        unit = direction / length
        normal = np.array([-unit[1], unit[0]])
        samples = []
        for t in np.linspace(0.12, 0.88, 64):
            base = a + direction * t
            best_value = 0.0
            best_point = None
            for offset in np.arange(-search_px, search_px + 0.5, 1.0):
                point = base + normal * offset
                x, y = int(round(point[0])), int(round(point[1]))
                if not (0 <= x < width and 0 <= y < height):
                    continue
                value = float(magnitude[y, x])
                if value > best_value:
                    best_value = value
                    best_point = point
            if best_point is not None and best_value > 30.0:
                samples.append(best_point)
        if len(samples) < 12:
            lines.append((a, b))
            continue
        points = np.array(samples)
        # Total least squares line through the accepted ridge samples.
        centred = points - points.mean(axis=0)
        _, _, vh = np.linalg.svd(centred, full_matrices=False)
        direction_fit = vh[0]
        mean = points.mean(axis=0)
        lines.append((mean - direction_fit * 10, mean + direction_fit * 10))

    def intersect(l1, l2):
        p = np.array(l1[0], dtype=np.float64)
        r = np.array(l1[1], dtype=np.float64) - p
        q = np.array(l2[0], dtype=np.float64)
        s = np.array(l2[1], dtype=np.float64) - q
        cross = r[0] * s[1] - r[1] * s[0]
        if abs(cross) < 1e-9:
            return None
        t = ((q[0] - p[0]) * s[1] - (q[1] - p[1]) * s[0]) / cross
        return p + r * t

    refined = []
    for index in range(4):
        previous = lines[(index - 1) % 4]
        current = lines[index]
        point = None
        if previous is not None and current is not None:
            point = intersect(previous, current)
        if point is None or not np.all(np.isfinite(point)):
            refined.append(quad_px[index])
        else:
            refined.append(point)
    refined = np.array(refined)
    # Reject a refinement that moved a corner implausibly far: that is a wrong
    # ridge, not a better corner.
    if np.max(np.linalg.norm(refined - quad_px, axis=1)) > 0.06 * max(width, height):
        return quad_px
    return refined


def _warp(image, quad_px: np.ndarray):
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
    width = max(2, width)
    height = max(2, height)
    destination = np.array(
        [[0, 0], [width - 1, 0], [width - 1, height - 1], [0, height - 1]],
        dtype=np.float32,
    )
    matrix = cv2.getPerspectiveTransform(
        quad_px.astype(np.float32), destination
    )
    return cv2.warpPerspective(image, matrix, (width, height))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--candidates", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--refined", type=Path, required=True)
    parser.add_argument("--sheets", type=Path, default=None)
    args = parser.parse_args()

    candidates = json.loads(args.candidates.read_text(encoding="utf-8"))
    images = sorted(
        p for p in (args.dataset / "images_original").iterdir() if p.is_file()
    )
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    refined_entries = []
    crops = []
    for entry in candidates:
        index = int(entry["image_index"])
        path = images[index - 1]
        image = _load(path)
        height, width = image.shape[:2]
        quad = _order(_to_pixels(entry["points_norm"], width, height))
        refined = _refine(image, quad)
        crop = _warp(image, refined)
        scale = TARGET_LONG_EDGE / max(crop.shape[:2])
        crop_view = cv2.resize(
            crop,
            (max(1, int(crop.shape[1] * scale)), max(1, int(crop.shape[0] * scale))),
            interpolation=cv2.INTER_AREA,
        )
        label = f"i{index:03d} #{entry['instance']}"
        cv2.rectangle(
            crop_view, (0, 0), (crop_view.shape[1] - 1, crop_view.shape[0] - 1), (0, 0, 255), 2
        )
        cv2.putText(
            crop_view,
            label,
            (6, 22),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.65,
            (0, 0, 255),
            2,
        )
        crops.append(crop_view)
        refined_entries.append(
            {
                "image_index": index,
                "filename": entry.get("filename") or path.name,
                "instance": entry["instance"],
                "draft_source": entry.get("source", "unknown"),
                "points_norm": [
                    [
                        round(float(x) / max(1, width - 1), 6),
                        round(float(y) / max(1, height - 1), 6),
                    ]
                    for x, y in refined
                ],
                "verified": False,
                "warp_px": [
                    int(np.ptp(refined[:, 0])),
                    int(np.ptp(refined[:, 1])),
                ],
            }
        )

    (args.refined).write_text(
        json.dumps(refined_entries, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    if args.sheets:
        args.sheets.mkdir(parents=True, exist_ok=True)
        cell = (TARGET_LONG_EDGE, TARGET_LONG_EDGE)
        per_sheet = 6
        for start in range(0, len(crops), per_sheet):
            chunk = crops[start : start + per_sheet]
            sheet = np.full(
                (cell[1] * 3, cell[0] * 2, 3), 245, dtype=np.uint8
            )
            for slot, crop in enumerate(chunk):
                x = (slot % 2) * cell[0]
                y = (slot // 2) * cell[1]
                h = min(cell[1], crop.shape[0])
                w = min(cell[0], crop.shape[1])
                sheet[y : y + h, x : x + w] = crop[:h, :w]
            cv2.imwrite(
                str(args.sheets / f"warp_sheet_{start // per_sheet + 1:02d}.png"),
                sheet,
            )
    print(
        json.dumps(
            {
                "candidates": len(candidates),
                "crops": len(crops),
                "sheets": (len(crops) + 5) // 6,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
