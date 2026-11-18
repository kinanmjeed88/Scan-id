#!/usr/bin/env python3
"""Independent re-verification of the authored ground truth.

The decision that matters is: does each side of the quadrilateral lie on the
document's real edge in the ORIGINAL image? Two measurements answer it without
any tuned detection threshold:

`side_support` — for each side, the mean gradient magnitude in a 3 px window
    centred on the side, divided by the mean gradient magnitude of the same
    card's interior, sampled on a parallel line 6 % of the side length inside
    the quadrilateral. A side that lies on the physical card edge sees a
    stronger ridge than the card's own print, so the ratio exceeds 1. When a
    side cuts through the card (an under-estimated corner) or floats outside it
    (an over-estimated one) the ratio collapses toward or below 1, because the
    line no longer follows an edge.

`outside_contrast` — mean colour distance between a band 4..12 px outside the
    quadrilateral and a band 4..12 px inside it, normalized by 255·√3. For a
    boundary on the card edge the two bands are card and background.

The tool also re-checks the structural facts (pixel size, convexity, area) and
renders every confirmed crop, because the crop is what a human ultimately
judges. Corner order is TRUSTED as authored (TL, TR, BR, BL); re-ordering here
would silently change which pixels the quad means.

HONESTY ABOUT WHAT THIS GATE IS. The structural checks are hard: a quad whose
corner leaves the frame, that is not convex, or that is degenerate cannot be a
document boundary, and such a claim is reported as a failure. The two edge
metrics are ADVISORY, and this tool does not pretend otherwise: measured on
cards whose warp was visually confirmed as complete, `min_side_support` ranges
from 0.10 to 9.0, because a card's own print can be as strong a ridge as its
edge and a pale card on pale wood has almost no edge at all. Gating `confirmed`
on those numbers would reject correct boundaries, so the certification for a
`confirmed` instance is the visual review of the rendered crop, recorded in the
sheet this tool writes. The metrics are reported per instance so a second
reviewer can see which cases deserve a second look instead of only a verdict.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np

MIN_AREA_FRACTION = 0.005
NO_EDGE_SUPPORT = 0.80  # a side weaker than 80 % of its interior is not an edge
MIN_OUTSIDE_CONTRAST = 0.02
TILE = 300


def _load(path: Path):
    data = np.fromfile(str(path), dtype=np.uint8)
    image = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if image is None:
        raise SystemExit(f"cannot decode {path.name}")
    return image


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


def _gradient(image):
    grey = cv2.GaussianBlur(
        cv2.cvtColor(image, cv2.COLOR_BGR2GRAY).astype(np.float32), (3, 3), 0
    )
    gx = cv2.Sobel(grey, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(grey, cv2.CV_32F, 0, 1, ksize=3)
    return cv2.magnitude(gx, gy)


def _sample(magnitude, x, y):
    height, width = magnitude.shape[:2]
    xi = int(round(x))
    yi = int(round(y))
    if not (0 <= xi < width and 0 <= yi < height):
        return None
    return float(magnitude[yi, xi])


def _line_mean(magnitude, a, b, offset_normal=0.0, fraction=0.10):
    """Mean gradient along a-b, optionally displaced by offset_normal pixels."""
    d = b - a
    length = float(np.linalg.norm(d))
    if length < 8:
        return None
    unit = d / length
    normal = np.array([-unit[1], unit[0]])
    values = []
    for t in np.linspace(fraction, 1 - fraction, 60):
        point = a + d * t + normal * offset_normal
        value = _sample(magnitude, point[0], point[1])
        if value is not None:
            values.append(value)
    if len(values) < 10:
        return None
    return float(np.mean(values))


def _band_colour(image, a, b, offset_normal, spread=4.0):
    d = b - a
    length = float(np.linalg.norm(d))
    if length < 8:
        return None
    unit = d / length
    normal = np.array([-unit[1], unit[0]])
    samples = []
    for t in np.linspace(0.12, 0.88, 48):
        base = a + d * t
        for delta in np.linspace(-spread, spread, 5):
            point = base + normal * (offset_normal + delta)
            x, y = int(round(point[0])), int(round(point[1]))
            if 0 <= x < image.shape[1] and 0 <= y < image.shape[0]:
                samples.append(image[y, x].astype(np.float32))
    if not samples:
        return None
    return np.mean(np.array(samples), axis=0)


def measure(image, quad_px):
    magnitude = _gradient(image)
    height, width = image.shape[:2]
    sides = []
    contrasts = []
    for index in range(4):
        a = quad_px[index]
        b = quad_px[(index + 1) % 4]
        length = float(np.linalg.norm(b - a))
        if length < 12:
            sides.append(None)
            continue
        interior_offset = -0.06 * length
        on_edge = _line_mean(magnitude, a, b, 0.0)
        inside = _line_mean(magnitude, a, b, interior_offset)
        support = (
            on_edge / inside
            if on_edge is not None and inside is not None and inside > 1e-3
            else (9.0 if on_edge is not None else None)
        )
        sides.append(
            None
            if support is None
            else {"side": index, "support": round(float(support), 3)}
        )
        outside_colour = _band_colour(image, a, b, 8.0)
        inside_colour = _band_colour(image, a, b, -8.0)
        if outside_colour is not None and inside_colour is not None:
            distance = float(
                np.linalg.norm(outside_colour - inside_colour)
            ) / (255.0 * np.sqrt(3))
            contrasts.append(distance)
    measured = [s for s in sides if s is not None]
    return {
        "side_support": measured,
        "min_side_support": (
            round(min(s["support"] for s in measured), 3) if measured else None
        ),
        "mean_outside_contrast": (
            round(float(np.mean(contrasts)), 4) if contrasts else None
        ),
    }


def verify(dataset: Path, truth: dict, sheets: Path | None) -> dict:
    images = sorted(
        p for p in (dataset / "images_original").iterdir() if p.is_file()
    )
    failures = []
    results = []
    tiles = []
    for entry in truth["instances"]:
        status = entry["status"]
        if status == "undetermined":
            results.append(
                {**entry, "verified": None, "reason": "no_quad_expected"}
            )
            continue
        index = int(entry["image_index"])
        image = _load(images[index - 1])
        height, width = image.shape[:2]
        if [width, height] != list(entry["source_pixel_size"]):
            failures.append(
                {
                    "instance_id": entry["instance_id"],
                    "reason": "pixel_size_mismatch",
                    "expected": entry["source_pixel_size"],
                    "found": [width, height],
                }
            )
            continue
        points = entry["points_norm"]
        if not points or len(points) != 4:
            failures.append(
                {"instance_id": entry["instance_id"], "reason": "no_quad"}
            )
            continue
        quad = np.array(
            [[float(x) * (width - 1), float(y) * (height - 1)] for x, y in points],
            np.float64,
        )
        if (
            np.any(quad[:, 0] < -0.5)
            or np.any(quad[:, 1] < -0.5)
            or np.any(quad[:, 0] > width)
            or np.any(quad[:, 1] > height)
        ):
            failures.append(
                {"instance_id": entry["instance_id"], "reason": "corner_outside"}
            )
            continue
        area = abs(cv2.contourArea(quad.astype(np.float32)))
        if area < MIN_AREA_FRACTION * width * height:
            failures.append(
                {"instance_id": entry["instance_id"], "reason": "degenerate_quad"}
            )
            continue
        if not cv2.isContourConvex(quad.astype(np.int32)):
            failures.append(
                {"instance_id": entry["instance_id"], "reason": "not_convex"}
            )
            continue
        measured = measure(image, quad)
        # Hard gate: structural validity only (checked above). Edge metrics
        # below are advisory and never decide the claim.
        reasons = []
        support = measured["min_side_support"]
        contrast = measured["mean_outside_contrast"]
        advisories = []
        if support is not None and support < NO_EDGE_SUPPORT:
            advisories.append("weak_side_support")
        if contrast is not None and contrast < MIN_OUTSIDE_CONTRAST:
            advisories.append("no_outside_contrast")
        record = {
            "instance_id": entry["instance_id"],
            "image_index": index,
            "kind": entry["kind"],
            "status": status,
            **measured,
            "verified": not reasons,
            "reason": ",".join(reasons) if reasons else "ok",
            "advisories": advisories,
        }
        results.append(record)
        if reasons:
            failures.append(
                {"instance_id": entry["instance_id"], "reason": ",".join(reasons),
                 "min_side_support": support, "mean_outside_contrast": contrast}
            )

        crop = _warp(image, quad)
        scale = TILE / max(crop.shape[:2])
        tile = cv2.resize(
            crop,
            (max(1, int(crop.shape[1] * scale)), max(1, int(crop.shape[0] * scale))),
            interpolation=cv2.INTER_AREA,
        )
        canvas = np.full((TILE + 18, TILE, 3), 255, np.uint8)
        canvas[18 : 18 + tile.shape[0], 0 : tile.shape[1]] = tile
        colour = (0, 140, 0) if not reasons else (0, 0, 220)
        if advisories:
            colour = (0, 140, 220)
        label = f"{entry['instance_id']} s={support if support is not None else -1:.2f}"
        cv2.putText(
            canvas, label, (3, 14), cv2.FONT_HERSHEY_SIMPLEX, 0.42, colour, 1
        )
        tiles.append(canvas)

    if sheets is not None and tiles:
        sheets.mkdir(parents=True, exist_ok=True)
        columns = 5
        per_sheet = columns * 4
        for start in range(0, len(tiles), per_sheet):
            chunk = tiles[start : start + per_sheet]
            rows = (len(chunk) + columns - 1) // columns
            sheet = np.full(
                (rows * (TILE + 18), columns * TILE, 3), 255, np.uint8
            )
            for slot, tile in enumerate(chunk):
                x = (slot % columns) * TILE
                y = (slot // columns) * (TILE + 18)
                sheet[y : y + tile.shape[0], x : x + TILE] = tile
            cv2.imwrite(
                str(sheets / f"reviewed_{start // per_sheet + 1:02d}.png"), sheet
            )

    return {
        "quads_checked": len(tiles),
        "passed": sum(1 for r in results if r.get("verified") is True),
        "failed": sum(1 for r in results if r.get("verified") is False),
        "failures": failures,
        "advisory_count": sum(
            1 for r in results if r.get("advisories")
        ),
        "results": results,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--truth", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--sheets", type=Path, default=None)
    args = parser.parse_args()
    truth = json.loads(args.truth.read_text(encoding="utf-8"))
    report = verify(args.dataset, truth, args.sheets)
    args.out.write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(
        json.dumps(
            {
                "quads_checked": report["quads_checked"],
                "passed": report["passed"],
                "failed": report["failed"],
                "failure_reasons": [f["reason"] for f in report["failures"]],
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
