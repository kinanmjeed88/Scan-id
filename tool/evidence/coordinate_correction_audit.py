#!/usr/bin/env python3
"""Prove the five properties the coordinate correction must satisfy.

This ports `docQuadCorners` and `_snapToFrame` from lib/imaging/docquad_model.dart
and `normalizedQuadIssue` from lib/domain/geometry.dart, then asserts each
required property. It is evidence, not a substitute for the Dart tests: CI runs
those. Here the point is to state the acceptance criteria as executable checks so
"no widened tolerance" is a measured statement rather than a claim.

Usage: python tool/evidence/coordinate_correction_audit.py [--json out.json]
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EPSILON = 1e-9            # _snapToFrame's tolerance
FRAME_TOUCH = 0.016       # frameTouchTolerance, lib/imaging/boundary_arbitration
HEATMAP_CELL_PX_900 = 18.8  # one heatmap cell expressed on a 900 px frame


def letterbox(width: int, height: int, input_size: int = 256):
    scale = min(input_size / width, input_size / height)
    return scale, (input_size - width * scale) / 2, (input_size - height * scale) / 2


def snap(fraction: float) -> float:
    if fraction > 1 and fraction <= 1 + EPSILON:
        return 1.0
    if fraction < 0 and fraction >= -EPSILON:
        return 0.0
    return fraction


def doc_quad_corners(peaks, scale, ox, oy, width, height):
    span_x = max(1, width - 1)
    span_y = max(1, height - 1)
    return [
        (snap(((x - ox) / scale) / span_x), snap(((y - oy) / scale) / span_y))
        for x, y in peaks
    ]


def out_of_bounds(corners) -> bool:
    """Port of the exact predicate in normalizedQuadIssue."""
    return any(x < 0 or x > 1 or y < 0 or y > 1 for x, y in corners)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json")
    arguments = parser.parse_args()
    results = {}

    # ---- Property 1: the mapping returns the correct pixel. -----------------
    # A peak synthesised from pixel p must map back to p, for both endpoints and
    # the interior, on the shapes the app can actually produce.
    worst_round_trip = 0.0
    frames = [(1200, 900), (900, 1200), (1200, 1200), (1200, 275),
              (320, 1200), (64, 48), (40, 40)]
    for width, height in frames:
        scale, ox, oy = letterbox(width, height)
        for p in (0, 1, (width - 1) / 2, width - 2, width - 1):
            peak = (p * scale + ox, 0)
            (fx, _), = doc_quad_corners([peak], scale, ox, oy, width, height)
            worst_round_trip = max(worst_round_trip,
                                   abs(fx * (width - 1) - p))
    results["property_1_correct_pixels"] = {
        "worst_round_trip_px": worst_round_trip,
        "passed": worst_round_trip < 1e-9,
    }

    # ---- Property 2: an edge pixel is not rejected by numeric overshoot. ----
    # Frames whose last pixel overshoots 1.0 without snapping.
    overshooting, rescued, still_bad = 0, 0, 0
    for width in range(40, 1201, 1):
        for height in (40, 65, 275, 900, 1166, 1200):
            if height > width * 4 or width > height * 4:
                continue
            scale, ox, oy = letterbox(width, height)
            # A peak pair that is legitimately ON the frame's last pixel on
            # both axes; then vary one axis at a time.
            base_x = (width - 1) * scale + ox
            base_y = (height - 1) * scale + oy
            for axis, extent, offset, peak in (
                ("x", width, ox, base_x),
                ("y", height, oy, base_y),
            ):
                raw = (peak - offset) / scale / max(1, extent - 1)
                if raw <= 1:
                    continue
                overshooting += 1
                # Both axes stay on the last pixel: neither may be rejected.
                corners = doc_quad_corners(
                    [(base_x, base_y)], scale, ox, oy, width, height
                )
                if out_of_bounds(corners):
                    still_bad += 1
                else:
                    rescued += 1
    results["property_2_edge_not_rejected"] = {
        "overshooting_cases": overshooting,
        "rescued": rescued,
        "still_rejected": still_bad,
        "passed": still_bad == 0,
    }

    # ---- Property 3: a genuinely out-of-frame peak IS rejected. ------------
    # A peak in the letterbox padding is not a document corner.
    rejected = 0
    considered = 0
    # Sweep every frame shape the app can produce, and probe the padding band on
    # whichever axis has one. A peak deeper than EPSILON into the padding is not
    # a document corner and must not be rescued by the snap.
    probe_frames = [(w, h) for w in range(40, 1201, 7)
                    for h in (40, 65, 275, 480, 900, 1166, 1200)
                    if not (h > w * 4 or w > h * 4)]
    for width, height in probe_frames:
        scale, ox, oy = letterbox(width, height)
        for axis, offset, extent, other in (
            ("x", ox, width, (height - 1) / 2),
            ("y", oy, height, (width - 1) / 2),
        ):
            if offset <= EPSILON * scale:
                continue  # no padding on this axis
            # 0 is the outer edge of the padded axis; a heatmap peak there is
            # outside the image by construction.
            peak_x = 0.0 if axis == "x" else other * scale + ox
            peak_y = 0.0 if axis == "y" else other * scale + oy
            corners = doc_quad_corners(
                [(peak_x, peak_y)], scale, ox, oy, width, height
            )
            considered += 1
            if out_of_bounds(corners):
                rejected += 1
    results["property_3_outside_rejected"] = {
        "considered": considered,
        "rejected": rejected,
        "passed": rejected == considered and considered > 0,
    }

    # ---- Property 4: the tolerance is not widened. ------------------------
    # The snap must never move a coordinate that a real peak could produce by
    # more than EPSILON, and EPSILON must be negligible against both one heatmap
    # cell and the frame-touch band.
    snap_effects = []
    for value in (1 + 5e-10, 1 + 1e-10, 1 + 2e-9, 1 + 1e-6, 1.05,
                  -5e-10, -2e-9, -0.001, 0.5):
        snapped = snap(value)
        snap_effects.append(
            {"input": value, "output": snapped, "change": snapped - value}
        )
    max_change = max(abs(entry["change"]) for entry in snap_effects)
    results["property_4_tolerance_not_widened"] = {
        "max_change": max_change,
        "epsilon": EPSILON,
        "heatmap_cell_px_on_900": HEATMAP_CELL_PX_900,
        "frame_touch_band": FRAME_TOUCH,
        "epsilon_vs_heatmap_cell_pct": 100 * EPSILON / HEATMAP_CELL_PX_900,
        "values_untouched_beyond_epsilon": [
            entry for entry in snap_effects if abs(entry["input"] - 0.5) < 1
            and entry["input"] > 1 + EPSILON or entry["input"] < -EPSILON
        ],
        "passed": (
            max_change <= EPSILON
            and all(abs(e["change"]) == 0 or abs(e["change"]) <= EPSILON
                    for e in snap_effects)
            # a real out-of-frame value is still out of frame
            and snap(-0.001) < 0 and snap(1.05) > 1
        ),
    }

    # ---- Property 5: edge cases still behave. ----------------------------
    edge_cases = []
    for width, height in [(0, 0), (1, 1), (1, 1200), (1200, 1), (2, 2)]:
        scale, ox, oy = letterbox(max(width, 1), max(height, 1))
        corners = doc_quad_corners([(2, 2)], scale, ox, oy, width, height)
        finite = all(math.isfinite(v) for point in corners for v in point)
        edge_cases.append(
            {"frame": f"{width}x{height}", "corners": corners, "finite": finite}
        )
    results["property_5_edge_cases"] = {
        "cases": edge_cases,
        "passed": all(entry["finite"] for entry in edge_cases),
    }

    # ---- The documented bias of the old divisor, restated as a number. ----
    width = 1200
    results["old_divisor_bias"] = {
        "note": "f = index/extent then multiplied back by extent-1",
        "max_px": max(abs((index / width) * (width - 1) - index)
                      for index in range(width)),
        "always_inward": all(
            (index / width) * (width - 1) <= index for index in range(width)
        ),
    }

    failed = [name for name, entry in results.items()
              if isinstance(entry, dict) and entry.get("passed") is False]
    print("COORDINATE CORRECTION AUDIT")
    print("=" * 60)
    for name, entry in results.items():
        if not isinstance(entry, dict) or "passed" not in entry:
            continue
        mark = "PASS" if entry["passed"] else "FAIL"
        print(f"{mark}  {name}")
        for key, value in entry.items():
            if key in ("passed", "cases"):
                continue
            print(f"        {key}: {value}")
    print()
    print(f"old divisor bias: {results['old_divisor_bias']['max_px']:.6f} px max, "
          f"always inward = {results['old_divisor_bias']['always_inward']}")
    percent = results["property_4_tolerance_not_widened"][
        "epsilon_vs_heatmap_cell_pct"
    ]
    print(f"snap tolerance: {EPSILON} = {percent:.8f} % of one heatmap cell")
    print()
    print("RESULT:", "ALL PROPERTIES HOLD" if not failed else f"FAILED: {failed}")

    if arguments.json:
        Path(arguments.json).write_text(json.dumps(results, indent=2) + "\n")
        print(f"wrote {arguments.json}")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
