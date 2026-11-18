#!/usr/bin/env python3
"""Draft card quadrilaterals with a card-shaped component search.

Second drafting strategy, complementary to `draft_quads.py` (which follows
Canny contours): segment the image into connected regions by *local colour
contrast* against the dominant background, take each region's min-area
rectangle, and keep rectangles whose proportions and fill can be a physical
card (ID-1 / passport page / bank card, including mild perspective).

Still not ground truth: output is `"verified": false, "source":
"component-draft"` and each quad must be confirmed on the rendered warp.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np

MIN_AREA = 0.015
MAX_AREA = 0.92
ASPECT_RANGE = (1.15, 2.35)
MIN_FILL = 0.72  # region pixels / min-area-rectangle area


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


def _iou(a: np.ndarray, b: np.ndarray) -> float:
    inter, _ = cv2.intersectConvexConvex(
        a.astype(np.float32), b.astype(np.float32)
    )
    ua = abs(cv2.contourArea(a.astype(np.float32)))
    ub = abs(cv2.contourArea(b.astype(np.float32)))
    union = ua + ub - inter
    return float(inter / union) if union > 0 else 0.0


def candidates(image, max_side: int = 640) -> list[np.ndarray]:
    height, width = image.shape[:2]
    scale = min(1.0, max_side / max(width, height))
    work = (
        cv2.resize(
            image,
            (max(1, int(width * scale)), max(1, int(height * scale))),
            interpolation=cv2.INTER_AREA,
        )
        if scale < 1.0
        else image
    )
    frame = float(work.shape[0] * work.shape[1])
    lab = cv2.cvtColor(work, cv2.COLOR_BGR2LAB).astype(np.float32)
    channels = cv2.split(lab)
    found: list[tuple[float, np.ndarray]] = []
    for channel_index, channel in enumerate(channels):
        blur = cv2.GaussianBlur(channel, (7, 7), 0)
        # Both polarities matter: a dark card on a light table and a light
        # card on a dark table are equally common.
        for polarity in (cv2.THRESH_BINARY, cv2.THRESH_BINARY_INV):
            for block in (31, 61):
                binary = cv2.adaptiveThreshold(
                    blur.astype(np.uint8),
                    255,
                    cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                    polarity,
                    block,
                    -6,
                )
                kernel = np.ones((5, 5), np.uint8)
                cleaned = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel, iterations=3)
                cleaned = cv2.morphologyEx(cleaned, cv2.MORPH_OPEN, kernel, iterations=1)
                count, labels, stats, _ = cv2.connectedComponentsWithStats(
                    cleaned, connectivity=8
                )
                for label_index in range(1, count):
                    area = float(stats[label_index, cv2.CC_STAT_AREA])
                    fraction = area / frame
                    if not MIN_AREA <= fraction <= MAX_AREA:
                        continue
                    mask = (labels == label_index).astype(np.uint8)
                    mask = cv2.morphologyEx(
                        mask, cv2.MORPH_CLOSE, np.ones((7, 7), np.uint8)
                    )
                    contours, _ = cv2.findContours(
                        mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
                    )
                    if not contours:
                        continue
                    contour = max(contours, key=cv2.contourArea)
                    box = cv2.boxPoints(cv2.minAreaRect(contour))
                    box_area = abs(cv2.contourArea(box.astype(np.float32)))
                    if box_area <= 0 or area / box_area < MIN_FILL:
                        continue
                    sides = [
                        float(np.linalg.norm(box[(i + 1) % 4] - box[i]))
                        for i in range(4)
                    ]
                    aspect = max(sides) / max(1e-6, min(sides))
                    if not ASPECT_RANGE[0] <= aspect <= ASPECT_RANGE[1]:
                        continue
                    quad = _order(box)
                    found.append((fraction, quad))
    found.sort(key=lambda item: item[0], reverse=True)
    kept: list[np.ndarray] = []
    for fraction, quad in found:
        if any(_iou(quad, other) > 0.55 for other in kept):
            continue
        kept.append(quad)
        if len(kept) >= 6:
            break
    return kept


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--only-missing", type=Path, default=None,
                        help="candidates file whose image indices are skipped")
    args = parser.parse_args()
    skip: set[int] = set()
    if args.only_missing is not None:
        skip = {
            int(entry["image_index"])
            for entry in json.loads(args.only_missing.read_text(encoding="utf-8"))
        }
    images = sorted(
        p for p in (args.dataset / "images_original").iterdir() if p.is_file()
    )
    draft = []
    for index, path in enumerate(images, start=1):
        if index in skip:
            continue
        image = _load(path)
        height, width = image.shape[:2]
        for position, quad in enumerate(candidates(image), start=1):
            draft.append(
                {
                    "image_index": index,
                    "filename": path.name,
                    "instance": position,
                    "points_norm": [
                        [
                            round(float(x) / max(1, width - 1), 6),
                            round(float(y) / max(1, height - 1), 6),
                        ]
                        for x, y in quad
                    ],
                    "source": "component-draft",
                    "verified": False,
                }
            )
    args.out.write_text(
        json.dumps(draft, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(
        json.dumps(
            {
                "images": len(images) - len(skip),
                "quads": len(draft),
                "images_with_quads": len({e["image_index"] for e in draft}),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
