"""Numeric replay of lib/domain/corner_order.dart and frame_edge_band.dart.

The Flutter SDK is not installed in this environment, so `flutter test` cannot
run. This script re-derives the SAME arithmetic from the same formulas, so a
logic error in the geometry is still caught. It is NOT a substitute for the Dart
tests: it proves the formulas, not the Dart transcription.
"""
import math

def cross(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])

def seg_cross(p1, p2, p3, p4):
    d1, d2 = cross(p3, p4, p1), cross(p3, p4, p2)
    d3, d4 = cross(p1, p2, p3), cross(p1, p2, p4)
    return ((d1 > 0 > d2) or (d1 < 0 < d2)) and ((d3 > 0 > d4) or (d3 < 0 < d4))

def self_intersects(c):
    return seg_cross(c[0], c[1], c[2], c[3]) or seg_cross(c[1], c[2], c[3], c[0])

def canonical(c):
    if len(c) != 4:
        return c
    if any(not math.isfinite(p[0]) or not math.isfinite(p[1]) for p in c):
        return c
    twice = sum(c[i][0] * c[(i + 1) % 4][1] - c[(i + 1) % 4][0] * c[i][1] for i in range(4))
    if not math.isfinite(twice) or abs(twice) <= 1e-12:
        return c
    if self_intersects(c):
        return c
    o = list(c) if twice > 0 else list(reversed(c))
    start = min(range(4), key=lambda i: (o[i][0] + o[i][1], i))
    return [o[(start + i) % 4] for i in range(4)]

def min_cyclic_px(a, b, width, height):
    if len(a) != 4 or len(b) != 4:
        return math.inf
    if any(not math.isfinite(p[0]) or not math.isfinite(p[1]) for p in a + b):
        return math.inf
    if width < 2 or height < 2:
        return math.inf
    a, b = canonical(a), canonical(b)
    if len(a) != 4 or len(b) != 4:
        return math.inf
    best = math.inf
    for shift in range(4):
        worst = 0.0
        for i in range(4):
            dx = (a[i][0] - b[(i + shift) % 4][0]) * (width - 1)
            dy = (a[i][1] - b[(i + shift) % 4][1]) * (height - 1)
            d = math.hypot(dx, dy)
            if not math.isfinite(d):
                return math.inf
            worst = max(worst, d)
        best = min(best, worst)
    return best

def min_cyclic_fraction(a, b, width, height):
    px = min_cyclic_px(a, b, width, height)
    if not math.isfinite(px):
        return 1.0
    diag = math.hypot(width - 1, height - 1)
    return max(0.0, min(1.0, px / diag))

def quantisation_band(fw, fh, input_pixels, cells, max_fraction=0.05):
    if fw < 2 or fh < 2 or not math.isfinite(input_pixels) or input_pixels <= 0 \
       or cells <= 0 or not math.isfinite(max_fraction) or max_fraction <= 0:
        return (0.016, 0.016, 0.016, 0.016)
    scale = min(input_pixels / fw, input_pixels / fh)
    if not math.isfinite(scale) or scale <= 0:
        return (0.016, 0.016, 0.016, 0.016)
    cell_px = input_pixels / cells / scale
    left = min(max_fraction, cell_px / max(1, fw - 1))
    top = min(max_fraction, cell_px / max(1, fh - 1))
    if not math.isfinite(left) or not math.isfinite(top) or left <= 0 or top <= 0:
        return (0.016, 0.016, 0.016, 0.016)
    return (left, top, left, top)

def sides_touched(corners, band):
    left, top, right, bottom = band
    touched = set()
    for x, y in corners:
        if not math.isfinite(x) or not math.isfinite(y):
            continue
        if x <= left:
            touched.add('left')
        if x >= 1 - right:
            touched.add('right')
        if y <= top:
            touched.add('top')
        if y >= 1 - bottom:
            touched.add('bottom')
    return touched
