"""Runs the numeric replay of the remediation's geometry changes.

The Flutter SDK is not installed in this environment, so `flutter analyze` and
`flutter test` cannot run. This driver re-derives the same arithmetic from the
same formulas so a LOGIC error in the geometry is still caught. It is not a
substitute for the Dart tests: it proves the formulas, not the Dart
transcription, and it never exercises the widgets, the ONNX runtime, or an
image.

Usage:  python3 tool/evidence/run_corner_order_replay.py
Exit code 0 means every numeric check passed.
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from corner_order_replay import (  # noqa: E402
    canonical,
    min_cyclic_fraction,
    min_cyclic_px,
    quantisation_band,
    self_intersects,
    sides_touched,
)

FAILS = []


def check(name, condition):
    print(("PASS  " if condition else "FAIL  ") + name)
    if not condition:
        FAILS.append(name)


TL = [(.2, .2), (.8, .2), (.8, .8), (.2, .8)]
CROSSED = [(.2, .2), (.8, .8), (.8, .2), (.2, .8)]

print("=== canonicalCornerRing ===")
check("idempotent", canonical(canonical(TL)) == canonical(TL))
check(
    "all four rotations normalise to one ring",
    len({tuple(canonical([TL[(i + s) % 4] for i in range(4)])) for s in range(4)}) == 1,
)
check("reversed ring is the same quadrilateral", min_cyclic_px(TL, list(reversed(TL)), 1000, 700) < 1e-9)
check(
    "mirrored ring is the same quadrilateral",
    min_cyclic_px(TL, [TL[1], TL[0], TL[3], TL[2]], 1000, 700) < 1e-9,
)
check("a bow-tie is returned untouched", canonical(CROSSED) == CROSSED)
check("a bow-tie is detected as self-intersecting", self_intersects(CROSSED))
check("a convex ring is not self-intersecting", not self_intersects(TL))

print("\n=== RC-08: index-paired vs cyclic disagreement (threshold 0.04) ===")


def old_disagreement(a, b, width, height):
    """The pre-fix formula: corner i against corner i, no rotation search."""
    diagonal_squared = float(width * width + height * height)
    worst = 0.0
    for i in range(4):
        dx = (a[i][0] - b[i][0]) * width
        dy = (a[i][1] - b[i][1]) * height
        worst = max(worst, math.sqrt((dx * dx + dy * dy) / diagonal_squared))
    return worst


cases = {
    "identical order": TL,
    "rotated by 1": [TL[1], TL[2], TL[3], TL[0]],
    "rotated by 2": [TL[2], TL[3], TL[0], TL[1]],
    "rotated by 3": [TL[3], TL[0], TL[1], TL[2]],
    "two corners swapped": [TL[0], TL[2], TL[1], TL[3]],
    "a different document": [(.05, .1), (.95, .1), (.95, .95), (.05, .95)],
}
print(f"{'case':22s} {'old':>8s} {'verdict':>10s} {'new':>9s} {'verdict':>10s}")
for name, other in cases.items():
    old = old_disagreement(TL, other, 1000, 700)
    new = min_cyclic_fraction(TL, other, 1000, 700)
    print(
        f"{name:22s} {old:8.4f} {'disagree' if old > .04 else 'agree':>10s} "
        f"{new:9.6f} {'disagree' if new > .04 else 'agree':>10s}"
    )

check(
    "every ROTATION of the same document now agrees (the RC-08 defect)",
    all(
        min_cyclic_fraction(TL, [TL[(i + s) % 4] for i in range(4)], 1000, 700) <= .04
        for s in range(4)
    ),
)
check(
    "the old formula reported those same rotations as disagreement",
    any(
        old_disagreement(TL, [TL[(i + s) % 4] for i in range(4)], 1000, 700) > .04
        for s in range(1, 4)
    ),
)
check(
    "a genuinely different document still disagrees",
    min_cyclic_fraction(TL, cases["a different document"], 1000, 700) > .04,
)
check(
    "a swapped pair still disagrees (not silently tolerated)",
    min_cyclic_fraction(TL, cases["two corners swapped"], 1000, 700) > .04,
)

print("\n=== RC-03: one heatmap cell as a fraction of each frame axis ===")
print(f"{'frame':12s} {'bandX':>9s} {'bandY':>9s}   relation to legacy .016")
for width, height in [(1200, 900), (900, 1200), (1200, 1200), (1200, 700), (700, 1200), (1200, 380)]:
    band = quantisation_band(width, height, 256, 64)
    print(
        f"{width}x{height:<7d} {band[0]:9.5f} {band[1]:9.5f}   "
        f"x={band[0] / .016 * 100:5.1f}% y={band[1] / .016 * 100:5.1f}%"
    )

print("\n=== RC-03: a corner exactly one cell inside the border ===")
for width, height in [(1200, 900), (900, 1200), (1200, 700), (700, 1200)]:
    band = quantisation_band(width, height, 256, 64)
    cx, cy = 1 - band[0], 1 - band[1]
    legacy = (cx >= 1 - .016, cy >= 1 - .016)
    derived = (cx >= 1 - band[0], cy >= 1 - band[1])
    print(
        f"{width}x{height}: corner@({cx:.5f},{cy:.5f})  "
        f"legacy=({'contact' if legacy[0] else 'MISSED'},"
        f"{'contact' if legacy[1] else 'MISSED'})  "
        f"derived=({'contact' if derived[0] else 'MISSED'},"
        f"{'contact' if derived[1] else 'MISSED'})"
    )
    check(f"{width}x{height}: derived band catches one cell in on BOTH axes", all(derived))
    check(f"{width}x{height}: legacy band missed it on at least one axis", not all(legacy))

print("\n=== RC-03: a corner two cells inside must NOT count as contact ===")
for width, height in [(1200, 900), (1200, 700), (700, 1200)]:
    band = quantisation_band(width, height, 256, 64)
    corner = (1 - 2 * band[0], 1 - 2 * band[1])
    touched = sides_touched([corner], band)
    print(f"{width}x{height}: corner@({corner[0]:.5f},{corner[1]:.5f}) touched={sorted(touched) or 'none'}")
    check(f"{width}x{height}: two cells inside is not frame contact", not touched)

print("\n=== RC-01: corner round-trip error of the fixed mapping ===")
#
# Models the production scheme exactly:
#   forward : tensor = fractional_offset + source_pixel * (scaled-1)/(source-1)
#   inverse : source = (tensor - fractional_offset) / same_scale
# The pre-fix scheme used the IDEAL resize factor and the ideal offset, which
# do not describe the panel the tensor actually contains.
random.seed(20261118)
worst_new = 0.0
worst_old = 0.0
worst_old_frame = None
for frame_w, frame_h in [
    (1200, 900),
    (900, 1200),
    (1200, 1200),
    (1200, 275),
    (320, 1200),
    (64, 48),
    (40, 40),
]:
    scale = min(256 / frame_w, 256 / frame_h)
    scaled_w = max(1, min(256, round(frame_w * scale)))
    scaled_h = max(1, min(256, round(frame_h * scale)))
    offset_x = (256 - scaled_w) / 2
    offset_y = (256 - scaled_h) / 2
    sx = (scaled_w - 1) / (frame_w - 1) if scaled_w > 1 and frame_w > 1 else scale
    sy = (scaled_h - 1) / (frame_h - 1) if scaled_h > 1 and frame_h > 1 else scale
    for _ in range(2000):
        px = random.uniform(0, max(0, frame_w - 1))
        py = random.uniform(0, max(0, frame_h - 1))
        tx = offset_x + px * sx
        ty = offset_y + py * sy
        worst_new = max(worst_new, abs((tx - offset_x) / sx - px), abs((ty - offset_y) / sy - py))
        # Pre-fix decode: ideal isotropic scale, ideal offset.
        old_px = (tx - (256 - frame_w * scale) / 2) / scale
        old_py = (ty - (256 - frame_h * scale) / 2) / scale
        err = max(abs(old_px - px), abs(old_py - py))
        if err > worst_old:
            worst_old = err
            worst_old_frame = (frame_w, frame_h)

print(f"worst fixed round-trip error: {worst_new:.3e} px over 14,000 samples")
print(f"worst pre-fix round-trip error: {worst_old:.2f} px on {worst_old_frame}")
check("the fixed mapping round-trips to floating-point precision", worst_new < 1e-9)
check("the pre-fix mapping was measurably wrong (>1 px)", worst_old > 1.0)

print("\n=== RC-01: a peak in letterbox padding must decode OUTSIDE the frame ===")
# Regression for a defect introduced and then removed during this change: when
# the recorded offset disagreed with the offset the pixels were written at, a
# peak in the padding decoded to a fraction of 4.38 instead of >1, turning a
# bogus detection into a plausible-looking corner.
for frame_w, frame_h in [(1200, 275), (1200, 900), (320, 1200)]:
    scale = min(256 / frame_w, 256 / frame_h)
    scaled_w = max(1, min(256, round(frame_w * scale)))
    scaled_h = max(1, min(256, round(frame_h * scale)))
    offset_x = (256 - scaled_w) / 2
    offset_y = (256 - scaled_h) / 2
    sx = (scaled_w - 1) / (frame_w - 1) if scaled_w > 1 and frame_w > 1 else scale
    sy = (scaled_h - 1) / (frame_h - 1) if scaled_h > 1 and frame_h > 1 else scale
    panel_bottom = offset_y + scaled_h - 1
    peak_y = offset_y + (63 + .5) * 4  # heatmap cell 63 centre
    fraction = ((peak_y - offset_y) / sy) / (frame_h - 1)
    inside_panel = peak_y <= panel_bottom
    print(
        f"{frame_w}x{frame_h}: panel rows {offset_y:.1f}..{panel_bottom:.1f}, "
        f"cell-63 peak at {peak_y:.1f} -> fraction {fraction:.4f} "
        f"({'inside panel' if inside_panel else 'in padding'})"
    )
    check(
        f"{frame_w}x{frame_h}: a padding peak is not turned into an in-frame corner",
        inside_panel or fraction > 1 or fraction < 0,
    )

print()
if FAILS:
    print(f"{len(FAILS)} CHECK(S) FAILED: {FAILS}")
    sys.exit(1)
print("ALL CHECKS PASSED")
