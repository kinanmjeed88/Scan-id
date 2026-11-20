#!/usr/bin/env python3
"""Draft quadrilateral proposals for human verification.

The packaged dataset ships `boundary_candidates.json` for 34 of the 57 images.
This tool proposes quads for the remaining ones (and re-proposes for the
packaged ones) so a human reviewer can accept, correct or reject each one on
the original image.

Nothing here is ground truth. Every emitted quad carries
`"verified": false, "source": "opencv-draft"` and the reviewer must confirm it
in the annotation studio. The draft is only an assistance step.

Algorithm (classical, deterministic):
  1. downscale to <= 900 px on the long side,
  2. bilateral filter + Canny + morphological close,
  3. find external contours, approximate each with a polygon, keep convex
     4-gons whose area fraction and aspect can be a document,
  4. order corners TL, TR, BR, BL and suppress overlapping duplicates.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np

MIN_AREA_FRACTION = 0.012
MAX_AREA_FRACTION = 0.98
MIN_SIDE_PX = 40


def _order(quad: np.ndarray) -> np.ndarray:
    """Order four points TL, TR, BR, BL (clockwise, screen space)."""
    pts = quad.reshape(4, 2).astype(np.float64)
    centre = pts.mean(axis=0)
    angles = np.arctan2(pts[:, 1] - centre[1], pts[:, 0] - centre[0])
    ring = pts[np.argsort(angles)]  # clockwise in image coordinates
    start = int(np.argmin([p[0] + p[1] for p in ring]))
    return np.roll(ring, -start, axis=0)


def _is_convex(quad: np.ndarray) -> bool:
    return bool(cv2.isContourConvex(quad.reshape(-1, 1, 2).astype(np.int32)))


def _aspect(quad: np.ndarray) -> float:
    sides = [
        float(np.linalg.norm(quad[(i + 1) % 4] - quad[i])) for i in range(4)
    ]
    return max(sides) / max(1e-6, min(sides))


def _iou(a: np.ndarray, b: np.ndarray) -> float:
    a32 = a.astype(np.float32)
    b32 = b.astype(np.float32)
    inter, _ = cv2.intersectConvexConvex(a32, b32)
    area_a = abs(cv2.contourArea(a32))
    area_b = abs(cv2.contourArea(b32))
    union = area_a + area_b - inter
    return float(inter / union) if union > 0 else 0.0


def propose(image_path: Path, max_side: int = 900) -> list[dict]:
    data = np.fromfile(str(image_path), dtype=np.uint8)
    image = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if image is None:
        return []
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
    grey = cv2.cvtColor(work, cv2.COLOR_BGR2GRAY)
    grey = cv2.bilateralFilter(grey, 9, 60, 60)
    proposals: list[tuple[float, np.ndarray, np.ndarray]] = []
    frame_area = float(work.shape[0] * work.shape[1])
    for low, high in ((30, 90), (60, 160), (100, 220)):
        edges = cv2.Canny(grey, low, high)
        edges = cv2.morphologyEx(
            edges, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8), iterations=2
        )
        contours, _ = cv2.findContours(
            edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE
        )
        contours = sorted(contours, key=cv2.contourArea, reverse=True)[:40]
        for contour in contours:
            area = cv2.contourArea(contour)
            fraction = area / frame_area
            if not MIN_AREA_FRACTION <= fraction <= MAX_AREA_FRACTION:
                continue
            perimeter = cv2.arcLength(contour, True)
            for epsilon in (0.02, 0.03, 0.05, 0.08):
                approx = cv2.approxPolyDP(contour, epsilon * perimeter, True)
                if len(approx) != 4 or not _is_convex(approx):
                    continue
                quad = _order(approx.reshape(4, 2))
                sides = [
                    float(np.linalg.norm(quad[(i + 1) % 4] - quad[i]))
                    for i in range(4)
                ]
                if min(sides) < MIN_SIDE_PX:
                    break
                aspect = _aspect(quad)
                if aspect > 8.0:
                    break
                proposals.append(
                    (fraction, quad, np.array([low, high], dtype=np.float64))
                )
                break

    proposals.sort(key=lambda item: item[0], reverse=True)
    kept: list[np.ndarray] = []
    for fraction, quad, _ in proposals:
        if any(_iou(quad, other) > 0.5 for other in kept):
            continue
        kept.append(quad)
        if len(kept) >= 8:
            break

    results = []
    for index, quad in enumerate(kept, start=1):
        results.append(
            {
                "instance": index,
                "points_norm": [
                    [
                        round(float(x) / max(1, work.shape[1] - 1), 6),
                        round(float(y) / max(1, work.shape[0] - 1), 6),
                    ]
                    for x, y in quad
                ],
                "source": "opencv-draft",
                "verified": False,
            }
        )
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    images = sorted(
        p for p in (args.dataset / "images_original").iterdir() if p.is_file()
    )
    draft = []
    for index, path in enumerate(images, start=1):
        for entry in propose(path):
            draft.append({"image_index": index, "filename": path.name, **entry})
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(draft, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    with_candidates = len({entry["image_index"] for entry in draft})
    print(
        json.dumps(
            {
                "images": len(images),
                "quads": len(draft),
                "images_with_quads": with_candidates,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
