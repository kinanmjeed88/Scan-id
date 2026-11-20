#!/usr/bin/env python3
"""Measure DocQuadNet corner and crop quality against synthetic ground truth.

This is a measurement harness, not a Dart run and not a shippable code path: it
re-implements `_letterbox`, `docQuadCorners`, `PerspectiveCoefficients.tryFrom`
and `warpPerspective` from lib/imaging/docquad_model.dart, lib/domain/geometry.dart
and lib/imaging/perspective.dart so the numbers describe the shipped formulas.
CI is what proves the Dart itself; this file proves the GEOMETRY of those
formulas against known quads, using the real bundled .ort graph.

Usage:
    python tool/evidence/docquad_crop_quality.py [--json out.json]

Every reported number comes from a run of this file; nothing is estimated.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path

try:
    import numpy as np
    from PIL import Image, ImageDraw
    import onnxruntime as ort
except ImportError as error:  # pragma: no cover - tooling only
    print(f"missing measurement dependency: {error}", file=sys.stderr)
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parents[2]
MODEL = ROOT / "assets/models/docquadnet256_trained_opset17.ort"
INPUT = 256
HEATMAP = 64
PREVIEW_BOUND = 1200  # maxRecognitionPreviewLongEdge
UNIT_CORNERS = ((0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0))


def letterbox(image: Image.Image) -> dict:
    """Port of DocQuadNet256._letterbox geometry."""
    width, height = image.size
    scale = min(INPUT / width, INPUT / height)
    scaled_width = max(1, min(INPUT, round(width * scale)))
    scaled_height = max(1, min(INPUT, round(height * scale)))
    offset_x = (INPUT - width * scale) / 2
    offset_y = (INPUT - height * scale) / 2
    left = int((INPUT - scaled_width) // 2)
    top = int((INPUT - scaled_height) // 2)
    canvas = Image.new("RGB", (INPUT, INPUT), (0, 0, 0))
    canvas.paste(
        image.resize((scaled_width, scaled_height), Image.BILINEAR), (left, top)
    )
    array = np.asarray(canvas, dtype=np.float32) / 255.0
    return {
        "tensor": array.transpose(2, 0, 1)[None],
        "scale": scale,
        "offsetX": offset_x,
        "offsetY": offset_y,
    }


def snap(fraction: float) -> float:
    """Port of _snapToFrame."""
    epsilon = 1e-9
    if 1 < fraction <= 1 + epsilon:
        return 1.0
    if -epsilon <= fraction < 0:
        return 0.0
    return fraction


def doc_quad_corners(peaks, box) -> list[tuple[float, float]]:
    """Port of docQuadCorners: un-letterbox, then divide by extent - 1."""
    frame_width, frame_height = box["frame"]
    span_x = max(1, frame_width - 1)
    span_y = max(1, frame_height - 1)
    return [
        (
            snap(((x - box["offsetX"]) / box["scale"]) / span_x),
            snap(((y - box["offsetY"]) / box["scale"]) / span_y),
        )
        for x, y in peaks
    ]


def perspective_coefficients(points):
    """Port of PerspectiveCoefficients.tryFrom (unit square -> quad)."""
    p = points
    dx1 = p[1][0] - p[2][0]
    dx2 = p[3][0] - p[2][0]
    dx3 = p[0][0] - p[1][0] + p[2][0] - p[3][0]
    dy1 = p[1][1] - p[2][1]
    dy2 = p[3][1] - p[2][1]
    dy3 = p[0][1] - p[1][1] + p[2][1] - p[3][1]
    g = h = 0.0
    if abs(dx3) + abs(dy3) >= 1e-12:
        determinant = dx1 * dy2 - dx2 * dy1
        if not math.isfinite(determinant) or abs(determinant) <= 1e-12:
            return None
        g = (dx3 * dy2 - dx2 * dy3) / determinant
        h = (dx1 * dy3 - dx3 * dy1) / determinant
    a = p[1][0] - p[0][0] + g * p[1][0]
    b = p[3][0] - p[0][0] + h * p[3][0]
    c = p[0][0]
    d = p[1][1] - p[0][1] + g * p[1][1]
    e = p[3][1] - p[0][1] + h * p[3][1]
    f = p[0][1]
    for denominator in (1.0, 1 + g, 1 + h, 1 + g + h):
        if not math.isfinite(denominator) or denominator <= 1e-9:
            return None
    return (a, b, c, d, e, f, g, h)


def project(coefficients, u: float, v: float) -> tuple[float, float]:
    a, b, c, d, e, f, g, h = coefficients
    denominator = g * u + h * v + 1
    return ((a * u + b * v + c) / denominator, (d * u + e * v + f) / denominator)


def edge_output_size(corners_px):
    """Port of CropDraft's averaged-edge output size."""
    def distance(first, second):
        return math.hypot(first[0] - second[0], first[1] - second[1])

    width = (distance(corners_px[0], corners_px[1]) + distance(corners_px[3], corners_px[2])) / 2
    height = (distance(corners_px[0], corners_px[3]) + distance(corners_px[1], corners_px[2])) / 2
    return width, height


def synthetic_page(width, height, quad):
    image = Image.new("RGB", (width, height), (30, 28, 26))
    draw = ImageDraw.Draw(image)
    draw.polygon([(x * width, y * height) for x, y in quad], fill=(246, 244, 238))
    for i in range(1, 11):
        y = 0.14 + 0.07 * i
        draw.line(
            [(0.19 * width, y * height), (0.81 * width, y * height)],
            fill=(60, 60, 75),
            width=max(1, height // 140),
        )
    return image


def infer(session, image):
    box = letterbox(image)
    box["frame"] = image.size
    heatmaps, _mask = session.run(None, {"input": box["tensor"]})
    peaks = []
    for channel in range(4):
        index = int(np.argmax(heatmaps[0, channel]))
        row, column = divmod(index, HEATMAP)
        peaks.append(((column + 0.5) * 4, (row + 0.5) * 4))
    return peaks, box


# Distinct documents: axis-aligned, mild perspective, strongly perspective,
# edge-touching, near-edge, landscape, portrait, square, unusual aspect.
SCENES = [
    ("landscape mild", 1200, 900,
     [(.15, .12), (.85, .15), (.83, .88), (.17, .85)]),
    ("portrait mild", 900, 1200,
     [(.14, .13), (.86, .16), (.84, .87), (.16, .84)]),
    ("square", 1200, 1200,
     [(.15, .15), (.85, .15), (.85, .85), (.15, .85)]),
    ("strong perspective", 1200, 1000,
     [(.24, .10), (.90, .26), (.78, .90), (.10, .72)]),
    ("touching left edge", 1200, 900,
     [(.00, .14), (.78, .16), (.76, .88), (.00, .86)]),
    ("touching all edges", 1200, 900,
     [(.00, .00), (1.00, .00), (1.00, 1.00), (.00, 1.00)]),
    ("near edge", 1200, 900,
     [(.04, .05), (.95, .06), (.94, .94), (.05, .93)]),
    ("unusual aspect 4.4:1", 1200, 275,
     [(.06, .12), (.94, .12), (.94, .88), (.06, .88)]),
    ("tall and narrow", 320, 1200,
     [(.12, .06), (.88, .08), (.86, .92), (.14, .90)]),
]


def geometry_only():
    """The pipeline with IDEAL peaks: isolates the formulas from the model.

    If this section is non-zero, the coordinate code is wrong. If it is zero and
    the model section is not, the error belongs to the network, not the mapping.
    """
    rows = []
    for name, width, height, quad in SCENES:
        blank = Image.new("RGB", (width, height))
        box = letterbox(blank)
        box["frame"] = (width, height)
        peaks = [
            (x * (width - 1) * box["scale"] + box["offsetX"],
             y * (height - 1) * box["scale"] + box["offsetY"])
            for x, y in quad
        ]
        corners = doc_quad_corners(peaks, box)
        corners_px = [(x * (width - 1), y * (height - 1)) for x, y in corners]
        truth_px = [(x * (width - 1), y * (height - 1)) for x, y in quad]
        diagonal = math.hypot(width - 1, height - 1)
        errors = [
            math.hypot(got[0] - want[0], got[1] - want[1])
            for got, want in zip(corners_px, truth_px)
        ]
        coefficients = perspective_coefficients(corners)
        reprojection = 0.0
        if coefficients is not None:
            reprojection = max(
                math.hypot(
                    (project(coefficients, u, v)[0] - corners[i][0]) * (width - 1),
                    (project(coefficients, u, v)[1] - corners[i][1]) * (height - 1),
                )
                for i, (u, v) in enumerate(UNIT_CORNERS)
            )
        out_width, out_height = edge_output_size(corners_px)
        truth_width, truth_height = edge_output_size(truth_px)
        rows.append(
            {
                "scene": name,
                "source": f"{width}x{height}",
                "corner_max_px": max(errors),
                "corner_max_pct_diag": 100 * max(errors) / diagonal,
                "reprojection_max_px": reprojection,
                "size_error_pct": 100 * abs(out_width - truth_width) / max(1.0, truth_width),
            }
        )
    return rows


def permutation_check(session):
    """Confirms corner identity: no cyclic shift fits the truth better.

    A channel-order or ring-order bug looks like a large corner error, so an
    error figure is only meaningful next to this check.
    """
    rows = []
    for name, width, height, quad in SCENES:
        peaks, box = infer(session, synthetic_page(width, height, quad))
        corners = doc_quad_corners(peaks, box)
        corners_px = [(x * (width - 1), y * (height - 1)) for x, y in corners]
        truth_px = [(x * (width - 1), y * (height - 1)) for x, y in quad]
        means = []
        for shift in range(4):
            total = sum(
                math.hypot(
                    corners_px[(i + shift) % 4][0] - truth_px[i][0],
                    corners_px[(i + shift) % 4][1] - truth_px[i][1],
                )
                for i in range(4)
            )
            means.append(total / 4)
        rows.append(
            {
                "scene": name,
                "shift_means_px": [round(value, 2) for value in means],
                "best_shift": means.index(min(means)),
            }
        )
    return rows


def measure(session):
    rows = []
    for name, width, height, quad in SCENES:
        peaks, box = infer(session, synthetic_page(width, height, quad))
        corners = doc_quad_corners(peaks, box)
        corners_px = [(x * (width - 1), y * (height - 1)) for x, y in corners]
        truth_px = [(x * (width - 1), y * (height - 1)) for x, y in quad]
        diagonal = math.hypot(width - 1, height - 1)

        errors = [
            math.hypot(got[0] - want[0], got[1] - want[1])
            for got, want in zip(corners_px, truth_px)
        ]
        # Reprojection error, defined as the round trip through the warp the
        # app actually performs: the four quad corners are the unit square's
        # image under the fitted homography, so mapping the unit corners
        # forward and comparing against the quad corners measures the numeric
        # error of `PerspectiveCoefficients` itself. This is exact by
        # construction at the corners, which is why it is reported separately
        # from the corner error the MODEL contributes.
        coefficients = perspective_coefficients(corners)
        reprojection = []
        if coefficients is not None:
            for index, (u, v) in enumerate(UNIT_CORNERS):
                mapped = project(coefficients, u, v)
                reprojection.append(
                    math.hypot(
                        (mapped[0] - corners[index][0]) * (width - 1),
                        (mapped[1] - corners[index][1]) * (height - 1),
                    )
                )
        out_width, out_height = edge_output_size(corners_px)
        truth_width, truth_height = edge_output_size(truth_px)
        rows.append(
            {
                "scene": name,
                "source": f"{width}x{height}",
                "corner_max_px": max(errors),
                "corner_mean_px": statistics.fmean(errors),
                "corner_max_pct_diag": 100 * max(errors) / diagonal,
                "reprojection_max_px": max(reprojection) if reprojection else None,
                "reprojection_mean_px": (
                    statistics.fmean(reprojection) if reprojection else None
                ),
                "output": f"{out_width:.1f}x{out_height:.1f}",
                "truth_size": f"{truth_width:.1f}x{truth_height:.1f}",
                "size_error_pct": 100
                * abs(out_width - truth_width)
                / max(1.0, truth_width),
                "outside_frame": any(
                    not (0 <= x <= 1 and 0 <= y <= 1) for x, y in corners
                ),
            }
        )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json")
    arguments = parser.parse_args()
    session = ort.InferenceSession(str(MODEL), providers=["CPUExecutionProvider"])

    geometry = geometry_only()
    print("A. GEOMETRY ONLY - ideal peaks, no model. Non-zero here means the")
    print("   coordinate arithmetic is wrong.")
    print(f"{'scene':22s} {'source':10s} {'corner max px':>14s} {'%diag':>7s} "
          f"{'reproj px':>10s} {'size err%':>10s}")
    for row in geometry:
        print(f"{row['scene']:22s} {row['source']:10s} "
              f"{row['corner_max_px']:14.4f} {row['corner_max_pct_diag']:7.4f} "
              f"{row['reprojection_max_px']:10.4f} {row['size_error_pct']:10.4f}")
    worst = max(row["corner_max_px"] for row in geometry)
    print(f"   worst corner error over all scenes: {worst:.4f} px")
    print(f"   worst reprojection error: "
          f"{max(row['reprojection_max_px'] for row in geometry):.4f} px")
    print(f"   worst output-size error: "
          f"{max(row['size_error_pct'] for row in geometry):.4f} %")

    print()
    print("B. MODEL ACCURACY - the same pipeline with the real bundled graph on")
    print("   flat synthetic renders. This measures the NETWORK, not the mapping.")
    rows = measure(session)
    header = (
        f"{'scene':22s} {'source':10s} {'cmax':>7s} {'cmean':>7s} "
        f"{'%diag':>6s} {'reproj':>7s} {'size err%':>9s}"
    )
    print(header)
    print("-" * len(header))
    for row in rows:
        reprojection = (
            f"{row['reprojection_max_px']:.2f}"
            if row["reprojection_max_px"] is not None
            else "n/a"
        )
        print(
            f"{row['scene']:22s} {row['source']:10s} "
            f"{row['corner_max_px']:7.2f} {row['corner_mean_px']:7.2f} "
            f"{row['corner_max_pct_diag']:6.2f} {reprojection:>7s} "
            f"{row['size_error_pct']:9.2f}"
        )
    print()
    print("C. CORNER IDENTITY - best cyclic shift per scene. best_shift must be 0")
    print("   for every row; anything else would mean the ring order is wrong.")
    permutations = permutation_check(session)
    for row in permutations:
        flag = "" if row["best_shift"] == 0 else "  <-- RING ORDER SUSPECT"
        print(f"   {row['scene']:22s} means={row['shift_means_px']} "
              f"best={row['best_shift']}{flag}")

    if arguments.json:
        Path(arguments.json).write_text(
            json.dumps(
                {
                    "note": (
                        "Pure-Python port of the shipped geometry. Not a Dart "
                        "run; CI runs the Dart tests. Synthetic imagery only."
                    ),
                    "geometry_only": geometry,
                    "model_on_synthetic": rows,
                    "corner_identity": permutations,
                },
                indent=2,
            )
            + "\n"
        )
        print(f"\nwrote {arguments.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
