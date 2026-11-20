#!/usr/bin/env python3
"""Review assistance for the boundary annotation dataset.

This tool is deliberately NOT a source of ground truth. It only:

1. reads the packaged OpenCV contour candidates (`boundary_candidates.json`)
   and re-measures them against the ORIGINAL image pixels,
2. draws numbered overlays (candidate id, quadrilateral, region) that a human
   reviewer inspects at the image's own resolution,
3. emits a review sheet listing every image so the reviewer can record the
   real instance count, boundary verdict and document type.

Ground truth is authored by the reviewer in the local annotation studio
(`tool/local_annotation_studio.html`, schema `scan-id-local-annotations-v2`),
never by this tool. Candidates stay `verified: false` unless the reviewer has
looked at them on the original.

Privacy: images and all derived overlays live under `local-data/`, which is
git-ignored. This tool writes nothing outside the paths it is given.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

try:
    import cv2
    import numpy as np
except ImportError:  # pragma: no cover - environment guard
    sys.exit(
        "OpenCV and numpy are required: "
        "pip install --break-system-packages opencv-python-headless numpy"
    )

# Overlay colours (BGR). Candidate quads are drawn in one colour so a reviewer
# cannot mistake a machine proposal for an accepted boundary.
QUAD_COLOUR = (0, 165, 255)
TEXT_COLOUR = (0, 0, 0)
LABEL_BG = (255, 255, 255)


def _load(image_path: Path) -> "np.ndarray":
    data = np.fromfile(str(image_path), dtype=np.uint8)
    image = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if image is None:
        raise SystemExit(f"cannot decode {image_path.name}")
    return image


def _quad_pixels(quad_norm: list[list[float]], width: int, height: int):
    return np.array(
        [
            [
                int(round(min(max(x, 0.0), 1.0) * (width - 1))),
                int(round(min(max(y, 0.0), 1.0) * (height - 1))),
            ]
            for x, y in quad_norm
        ],
        dtype=np.int32,
    )


def _measure(quad_norm, width, height) -> dict:
    """Measured geometry of one candidate, in source pixels."""
    pts = _quad_pixels(quad_norm, width, height).astype(np.float64)
    area = abs(cv2.contourArea(pts.astype(np.float32)))
    frame = float((width - 1) * (height - 1))
    edges = [
        float(np.linalg.norm(pts[(i + 1) % 4] - pts[i]))
        for i in range(4)
    ]
    long_edge = max(edges)
    short_edge = max(1e-6, min(edges))
    return {
        "area_fraction": area / frame if frame else 0.0,
        "area_px": area,
        "aspect": long_edge / short_edge,
        "edges_px": [round(value, 2) for value in edges],
    }


def _label(image, text: str, x: int, y: int, scale: float = 0.9) -> None:
    (width, height), baseline = cv2.getTextSize(
        text, cv2.FONT_HERSHEY_SIMPLEX, scale, 2
    )
    x = max(0, min(x, image.shape[1] - width - 2))
    y = max(height + 2, min(y, image.shape[0] - baseline - 2))
    cv2.rectangle(
        image,
        (x - 2, y - height - 2),
        (x + width + 2, y + baseline),
        LABEL_BG,
        -1,
    )
    cv2.putText(
        image, text, (x, y), cv2.FONT_HERSHEY_SIMPLEX, scale, TEXT_COLOUR, 2
    )


def _draw_grid(image) -> None:
    """Thirds grid + tick marks, so a reviewer can read positions by eye."""
    height, width = image.shape[:2]
    for fraction in (1 / 3, 2 / 3):
        x = int(width * fraction)
        y = int(height * fraction)
        cv2.line(image, (x, 0), (x, height), (200, 200, 200), 1)
        cv2.line(image, (0, y), (width, y), (200, 200, 200), 1)


def render_overlays(
    dataset_dir: Path, out_dir: Path, max_side: int = 1100
) -> dict:
    candidates_path = dataset_dir / "boundary_candidates.json"
    raw = json.loads(candidates_path.read_text(encoding="utf-8"))
    by_image: dict[int, list[dict]] = {}
    for entry in raw:
        entry.setdefault("verified", False)
        by_image.setdefault(int(entry["image_index"]), []).append(entry)

    images_dir = dataset_dir / "images_original"
    image_paths = sorted(p for p in images_dir.iterdir() if p.is_file())
    out_dir.mkdir(parents=True, exist_ok=True)

    measurements: dict[str, dict] = {}
    for index, path in enumerate(image_paths, start=1):
        image = _load(path)
        height, width = image.shape[:2]
        _draw_grid(image)
        for candidate in by_image.get(index, []):
            quad = _quad_pixels(candidate["points_norm"], width, height)
            cv2.polylines(image, [quad], True, QUAD_COLOUR, 3, cv2.LINE_AA)
            for corner_index, point in enumerate(quad):
                cv2.circle(image, tuple(int(v) for v in point), 6, (0, 0, 255), -1)
                _label(
                    image,
                    f"{corner_index + 1}",
                    int(point[0]) + 8,
                    int(point[1]) - 8,
                    0.6,
                )
            measured = _measure(candidate["points_norm"], width, height)
            measurements[
                f"{index}:{candidate['instance']}"
            ] = measured
            _label(
                image,
                f"#{candidate['instance']} area={measured['area_fraction']:.2f} "
                f"aspect={measured['aspect']:.2f}",
                int(quad[:, 0].min()),
                int(quad[:, 1].min()) - 10,
                0.7,
            )
        if not by_image.get(index):
            _label(image, "no machine candidate", 12, 40, 0.9)
        _label(image, f"image_{index:03d} {width}x{height}", 12, height - 14, 0.8)

        scale = min(1.0, max_side / max(width, height))
        if scale < 1.0:
            image = cv2.resize(
                image,
                (max(1, int(width * scale)), max(1, int(height * scale))),
                interpolation=cv2.INTER_AREA,
            )
        target = out_dir / f"image_{index:03d}_review.png"
        cv2.imwrite(str(target), image)

    return {
        "images": len(image_paths),
        "candidates": len(raw),
        "images_with_candidates": len(by_image),
        "measurements": measurements,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dataset",
        type=Path,
        required=True,
        help="directory holding images_original/ and boundary_candidates.json",
    )
    parser.add_argument(
        "--out", type=Path, required=True, help="overlay output directory"
    )
    parser.add_argument("--max-side", type=int, default=1100)
    args = parser.parse_args()
    summary = render_overlays(args.dataset, args.out, args.max_side)
    print(json.dumps({k: v for k, v in summary.items() if k != "measurements"},
                     ensure_ascii=False, indent=2))
    (args.out / "candidate_measurements.json").write_text(
        json.dumps(summary["measurements"], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
