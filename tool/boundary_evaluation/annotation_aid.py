#!/usr/bin/env python3
"""Annotation aid: per-image contact sheets with a labelled ruler grid.

Every tile carries a 10 % grid whose borders are labelled with the normalized
value, so a reviewer can write normalized corner coordinates to roughly 1 % of
the image while looking at the original pixels. The tool only renders aid
images; all ground truth is authored separately and verified on the rectified
crop.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np

TILE = 560


def _load(path: Path):
    data = np.fromfile(str(path), dtype=np.uint8)
    image = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if image is None:
        raise SystemExit(f"cannot decode {path.name}")
    return image


def _ruler(image, label: str, candidates: list[dict]) -> np.ndarray:
    height, width = image.shape[:2]
    overlay = image.copy()
    for step in range(1, 10):
        x = int(width * step / 10)
        y = int(height * step / 10)
        colour = (190, 190, 190) if step != 5 else (150, 150, 150)
        cv2.line(overlay, (x, 0), (x, height), colour, 1)
        cv2.line(overlay, (0, y), (width, y), colour, 1)
        cv2.putText(
            overlay,
            f"{step / 10:.1f}",
            (x + 2, 14),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.38,
            (0, 0, 255),
            1,
        )
        cv2.putText(
            overlay,
            f"{step / 10:.1f}",
            (2, max(12, y - 3)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.38,
            (0, 0, 255),
            1,
        )
    for entry in candidates:
        quad = np.array(
            [
                [
                    int(round(float(x) * (width - 1))),
                    int(round(float(y) * (height - 1))),
                ]
                for x, y in entry["points_norm"]
            ],
            dtype=np.int32,
        )
        cv2.polylines(overlay, [quad], True, (0, 165, 255), 2)
        cv2.putText(
            overlay,
            f"c{entry['instance']}",
            (int(quad[:, 0].min()), max(16, int(quad[:, 1].min()) - 4)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.6,
            (0, 165, 255),
            2,
        )
    scale = min(1.0, TILE / max(width, height))
    resized = cv2.resize(
        overlay,
        (max(1, int(width * scale)), max(1, int(height * scale))),
        interpolation=cv2.INTER_AREA,
    )
    canvas = np.full((TILE + 26, TILE, 3), 255, dtype=np.uint8)
    canvas[26 : 26 + resized.shape[0], 0 : resized.shape[1]] = resized
    cv2.putText(
        canvas,
        f"{label}  {width}x{height}",
        (4, 18),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.6,
        (0, 0, 0),
        2,
    )
    return canvas


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--candidates", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--per-sheet", type=int, default=4)
    parser.add_argument("--first", type=int, default=1)
    parser.add_argument("--last", type=int, default=10_000)
    args = parser.parse_args()

    candidates = json.loads(args.candidates.read_text(encoding="utf-8"))
    by_image: dict[int, list[dict]] = {}
    for entry in candidates:
        by_image.setdefault(int(entry["image_index"]), []).append(entry)
    images = sorted(
        p for p in (args.dataset / "images_original").iterdir() if p.is_file()
    )
    args.out.mkdir(parents=True, exist_ok=True)
    columns = 2
    rows = max(1, args.per_sheet // columns)
    sheet = None
    slot = 0
    sheet_index = 0
    written = []
    for index, path in enumerate(images, start=1):
        if index < args.first or index > args.last:
            continue
        tile = _ruler(_load(path), f"image_{index:03d}", by_image.get(index, []))
        if sheet is None:
            sheet = np.full(
                (rows * tile.shape[0], columns * TILE, 3), 255, dtype=np.uint8
            )
            slot = 0
            sheet_index += 1
        x = (slot % columns) * TILE
        y = (slot // columns) * tile.shape[0]
        sheet[y : y + tile.shape[0], x : x + TILE] = tile
        slot += 1
        if slot >= rows * columns:
            name = args.out / f"aid_{sheet_index:02d}.png"
            cv2.imwrite(str(name), sheet)
            written.append(name.name)
            sheet = None
    if sheet is not None:
        name = args.out / f"aid_{sheet_index:02d}.png"
        cv2.imwrite(str(name), sheet)
        written.append(name.name)
    print(json.dumps({"sheets": written}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
