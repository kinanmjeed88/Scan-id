#!/usr/bin/env python3
"""Measure DocQuadNet corner accuracy on REALISTIC synthetic captures.

Why this file exists next to docquad_crop_quality.py: the flat renders there are
a weak proxy for a camera frame, and a model trained on photographs should not be
judged on untextured polygons. This renders scenes with the effects that actually
move a detector: a textured desk, a soft drop shadow, paper shading, printed text
lines, an off-axis camera stand-in (perspective quad), sensor blur and JPEG
compression.

It is still SYNTHETIC. Nothing here is evidence about real photographs, and the
report must keep the two apart: no real document image exists in this workspace
and none may be published to CI.

Metrics, reported separately:
  * detection rate     - a usable quad was returned at all
  * corner error       - per-corner distance to ground truth, in px and % diagonal
  * IoU                - quad overlap with ground truth
  * crop size error    - averaged-edge output size vs the truth quad's

Usage:
    python tool/evidence/docquad_realistic_accuracy.py [--json out.json]
"""

from __future__ import annotations

import argparse
import io
import json
import math
import random
import statistics
import sys
from pathlib import Path

try:
    import numpy as np
    import onnxruntime as ort
    from PIL import Image, ImageDraw, ImageFilter
except ImportError as error:  # pragma: no cover - tooling only
    print(f"missing measurement dependency: {error}", file=sys.stderr)
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parents[2]
MODEL = ROOT / "assets/models/docquadnet256_trained_opset17.ort"
INPUT, HEATMAP = 256, 64
SEED = 20261118
TRIALS_PER_SHAPE = 6


def letterbox(image: Image.Image):
    width, height = image.size
    scale = min(INPUT / width, INPUT / height)
    sw = max(1, min(INPUT, round(width * scale)))
    sh = max(1, min(INPUT, round(height * scale)))
    canvas = Image.new("RGB", (INPUT, INPUT), (0, 0, 0))
    canvas.paste(image.resize((sw, sh), Image.BILINEAR),
                 (int((INPUT - sw) // 2), int((INPUT - sh) // 2)))
    array = np.asarray(canvas, dtype=np.float32) / 255.0
    return {
        "tensor": array.transpose(2, 0, 1)[None],
        "scale": scale,
        "offsetX": (INPUT - width * scale) / 2,
        "offsetY": (INPUT - height * scale) / 2,
        "size": (width, height),
    }


def snap(fraction: float) -> float:
    if 1 < fraction <= 1 + 1e-9:
        return 1.0
    if -1e-9 <= fraction < 0:
        return 0.0
    return fraction


def sigmoid(value: float) -> float:
    if value >= 0:
        return 1 / (1 + math.exp(-value))
    return math.exp(value) / (1 + math.exp(value))


def corner_mask_iou(peaks64, mask) -> float:
    """Port of DocQuadNet256._cornerMaskIou.

    Peaks are in HEATMAP CELL units here (`_Peak.x` = column + 0.5), not the
    256-space x4 values. Feeding 256-space values against a 64-space mask
    silently returns ~0 and makes the production gate look broken; that mistake
    was made and corrected while building this file.
    """
    intersection = union = 0
    for y in range(HEATMAP):
        for x in range(HEATMAP):
            inside = False
            for index in range(4):
                a = peaks64[index]
                b = peaks64[(index + 1) % 4]
                if (a[1] > y + .5) != (b[1] > y + .5) and (
                    x + .5
                    < a[0] + (y + .5 - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
                ):
                    inside = not inside
            in_mask = bool(mask[y][x] > 0)
            if inside and in_mask:
                intersection += 1
            if inside or in_mask:
                union += 1
    return intersection / union if union else 0.0


# DocQuadNet256._minimumReviewEvidence
MINIMUM_REVIEW_EVIDENCE = 0.05


def corners_of(peaks, box):
    width, height = box["size"]
    sx, sy = max(1, width - 1), max(1, height - 1)
    return [
        (snap(((x - box["offsetX"]) / box["scale"]) / sx),
         snap(((y - box["offsetY"]) / box["scale"]) / sy))
        for x, y in peaks
    ]


def capture(width, height, quad, rng: random.Random):
    """A desk shot: texture, shadow, shaded paper, print, blur, JPEG."""
    desk = np.zeros((height, width, 3), np.float32)
    base = np.array([104, 78, 58], np.float32)
    desk[:, :] = base
    noise = np.random.normal(0, 6, (height, width, 3)).astype(np.float32)
    desk = np.clip(desk + noise, 0, 255).astype(np.uint8)
    image = Image.fromarray(desk)

    polygon = [(x * width, y * height) for x, y in quad]

    shadow = Image.new("L", (width, height), 0)
    ImageDraw.Draw(shadow).polygon(
        [(x + width * 0.012, y + height * 0.016) for x, y in polygon], fill=120
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(max(3, width // 90)))
    image = Image.composite(
        Image.new("RGB", (width, height), (16, 11, 7)), image, shadow
    )

    paper = Image.new("RGB", (width, height), (248, 246, 240))
    draw = ImageDraw.Draw(paper)
    # Printed lines with varying length, like real text blocks.
    for row in range(16):
        top = 0.09 + 0.052 * row
        right = 0.90 - rng.uniform(0, 0.22)
        draw.line(
            [(0.10 * width, top * height), (right * width, top * height)],
            fill=(34, 34, 46),
            width=max(1, int(height // 190)),
        )
    draw.rectangle(
        [0.10 * width, 0.045 * height, 0.44 * width, 0.075 * height],
        fill=(22, 22, 32),
    )
    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).polygon(polygon, fill=255)
    image = Image.composite(paper, image, mask)

    image = image.filter(ImageFilter.GaussianBlur(rng.uniform(0.8, 1.6)))
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=rng.randint(70, 86))
    buffer.seek(0)
    return Image.open(buffer).convert("RGB")


def quad_for(width, height, rng: random.Random):
    """A plausible hand-held capture: perspective, off-centre, fully in frame."""
    margin = rng.uniform(0.045, 0.13)
    left = margin + rng.uniform(0, 0.05)
    right = 1 - margin - rng.uniform(0, 0.05)
    top = margin + rng.uniform(0, 0.05)
    bottom = 1 - margin - rng.uniform(0, 0.05)
    skew = rng.uniform(0.01, 0.05)
    return [
        (left + rng.uniform(0, skew), top + rng.uniform(0, skew)),
        (right - rng.uniform(0, skew), top + rng.uniform(0, skew)),
        (right - rng.uniform(0, skew), bottom - rng.uniform(0, skew)),
        (left + rng.uniform(0, skew), bottom - rng.uniform(0, skew)),
    ]


def polygon_area(points):
    total = 0.0
    for index, (x, y) in enumerate(points):
        nx, ny = points[(index + 1) % len(points)]
        total += x * ny - nx * y
    return abs(total) / 2


def iou(first, second):
    from PIL import ImageDraw as _D

    def raster(points, size=512):
        mask = Image.new("L", (size, size), 0)
        _D.Draw(mask).polygon([(x * size, y * size) for x, y in points], fill=255)
        return np.asarray(mask) > 0

    a, b = raster(first), raster(second)
    union = np.logical_or(a, b).sum()
    return float(np.logical_and(a, b).sum() / union) if union else 0.0


def edge_sizes(points):
    def d(p, q):
        return math.hypot(p[0] - q[0], p[1] - q[1])

    width = (d(points[0], points[1]) + d(points[3], points[2])) / 2
    height = (d(points[0], points[3]) + d(points[1], points[2])) / 2
    return width, height


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json")
    arguments = parser.parse_args()
    rng = random.Random(SEED)
    np.random.seed(SEED)
    session = ort.InferenceSession(str(MODEL), providers=["CPUExecutionProvider"])

    shapes = [(1200, 900), (900, 1200), (1200, 1200), (1200, 700),
              (700, 1200), (1200, 380)]
    rows = []
    for width, height in shapes:
        for trial in range(TRIALS_PER_SHAPE):
            truth = quad_for(width, height, rng)
            image = capture(width, height, truth, rng)
            box = letterbox(image)
            heatmaps, _mask = session.run(None, {"input": box["tensor"]})
            peaks = []
            for channel in range(4):
                index = int(np.argmax(heatmaps[0, channel]))
                row, column = divmod(index, HEATMAP)
                peaks.append(((column + 0.5) * 4, (row + 0.5) * 4))
            peaks64 = [(x / 4, y / 4) for x, y in peaks]
            probabilities = [
                sigmoid(float(heatmaps[0, channel].ravel()[
                    int(np.argmax(heatmaps[0, channel]))
                ]))
                for channel in range(4)
            ]
            evidence = corner_mask_iou(peaks64, _mask[0, 0]) * min(probabilities)
            gate_passes = evidence >= MINIMUM_REVIEW_EVIDENCE
            detected = corners_of(peaks, box)
            inside = all(0 <= x <= 1 and 0 <= y <= 1 for x, y in detected)
            diagonal = math.hypot(width - 1, height - 1)
            errors = [
                math.hypot((d[0] - t[0]) * (width - 1), (d[1] - t[1]) * (height - 1))
                for d, t in zip(detected, truth)
            ]
            ow, oh = edge_sizes([(x * (width - 1), y * (height - 1))
                                 for x, y in detected])
            tw, th = edge_sizes([(x * (width - 1), y * (height - 1))
                                 for x, y in truth])
            rows.append(
                {
                    "shape": f"{width}x{height}",
                    "trial": trial,
                    "in_frame": inside,
                    "evidence": evidence,
                    "gate_passes": gate_passes,
                    "corner_max_px": max(errors),
                    "corner_mean_px": statistics.fmean(errors),
                    "corner_max_pct_diag": 100 * max(errors) / diagonal,
                    "iou": iou(detected, truth),
                    "crop_size_error_pct": 100 * abs(ow - tw) / max(1.0, tw),
                }
            )

    total = len(rows)
    accepted = [row for row in rows if row["gate_passes"]]
    print(f"SYNTHETIC REALISTIC CAPTURES  ({total} scenes, seed {SEED})")
    print("These simulate a desk shot; they are NOT real photographs.")
    print()
    print("Scored through the PRODUCTION gate (_minimumReviewEvidence = "
          f"{MINIMUM_REVIEW_EVIDENCE}), not on raw output:")
    print(f"  proposals the app would keep : {len(accepted)}/{total} "
          f"({100*len(accepted)/total:.1f} %)")
    rejected = [row for row in rows if not row["gate_passes"]]
    over_rejected = [row for row in rejected if row["iou"] >= 0.9]
    bad_accept = [row for row in accepted if row["iou"] < 0.9]
    print(f"  over-rejected good quads (IoU>=0.90) : {len(over_rejected)}")
    print(f"  accepted poor quads (IoU<0.90)       : {len(bad_accept)}")
    if accepted:
        for key, label in (("corner_max_px", "corner max px"),
                           ("corner_mean_px", "corner mean px"),
                           ("corner_max_pct_diag", "corner max % diag"),
                           ("iou", "IoU"),
                           ("crop_size_error_pct", "crop size err %")):
            values = [row[key] for row in accepted]
            values.sort()
            print(f"  {label:20s} median {statistics.median(values):8.3f}  "
                  f"p90 {values[int(len(values)*0.9)-1]:8.3f}  "
                  f"max {values[-1]:8.3f}")
        good = [row for row in accepted if row["iou"] >= 0.9]
        print(f"  of the kept proposals, IoU >= 0.90 : {len(good)}/{len(accepted)} "
              f"({100*len(good)/max(1,len(accepted)):.1f} %)")

    print()
    print("per-shape breakdown (scored through the production gate)")
    for width, height in shapes:
        shape = f"{width}x{height}"
        every = [row for row in rows if row["shape"] == shape]
        subset = [row for row in every if row["gate_passes"]]
        if not subset:
            print(f"  {shape:10s} gate kept 0/{len(every)}")
            continue
        median_corner = statistics.median(r["corner_max_px"] for r in subset)
        median_iou = statistics.median(r["iou"] for r in subset)
        print(f"  {shape:10s} kept {len(subset)}/{len(every)}  "
              f"median corner {median_corner:7.2f} px  "
              f"median IoU {median_iou:.3f}")

    if arguments.json:
        Path(arguments.json).write_text(
            json.dumps(
                {
                    "note": "Synthetic realistic captures. Not real photographs.",
                    "seed": SEED,
                    "rows": rows,
                },
                indent=2,
            )
            + "\n"
        )
        print(f"\nwrote {arguments.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
