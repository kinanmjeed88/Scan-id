"""Pure-geometry evidence for lib/domain/physical_aspect.dart.

A line-for-line Python port of estimatePhysicalAspect, run on synthetic,
licensed-free rectangles seen through a pinhole camera. It is NOT a Dart run:
it documents the arithmetic and the bounds used by
test/domain/physical_aspect_test.dart. Run: python3 tool/evidence/physical_aspect_grid.py
Writes tool/evidence/physical_aspect_results.json next to this file.
"""

import json
import math
import os

MIN_F, MAX_F = 0.25, 4.0
MIN_A, MAX_A = 0.1, 10.0


def rot_x(t):
    c, s = math.cos(t), math.sin(t)
    return [[1, 0, 0], [0, c, -s], [0, s, c]]


def rot_y(t):
    c, s = math.cos(t), math.sin(t)
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


def rot_z(t):
    c, s = math.cos(t), math.sin(t)
    return [[c, -s, 0], [s, c, 0], [0, 0, 1]]


def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def intersect(a, b, c, d):
    rx, ry = b[0] - a[0], b[1] - a[1]
    sx, sy = d[0] - c[0], d[1] - c[1]
    den = rx * sy - ry * sx
    scale = math.sqrt((rx * rx + ry * ry) * (sx * sx + sy * sy))
    if not (scale > 0) or abs(den) <= 1e-12 * scale:
        return None
    t = ((c[0] - a[0]) * sy - (c[1] - a[1]) * sx) / den
    x, y = a[0] + t * rx, a[1] + t * ry
    if not (math.isfinite(x) and math.isfinite(y)):
        return None
    return (x, y)


def solve(a, b):
    n = len(b)
    m = [a[i][:] + [b[i]] for i in range(n)]
    for c in range(n):
        pivot = c
        for r in range(c + 1, n):
            if abs(m[r][c]) > abs(m[pivot][c]):
                pivot = r
        if not (abs(m[pivot][c]) > 1e-12):
            return None
        m[c], m[pivot] = m[pivot], m[c]
        for r in range(n):
            if r == c:
                continue
            f = m[r][c] / m[c][c]
            for k in range(c, n + 1):
                m[r][k] -= f * m[c][k]
    x = [m[i][n] / m[i][i] for i in range(n)]
    return x if all(math.isfinite(v) for v in x) else None


def unit_square_homography(q):
    src = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
    rows, rhs = [], []
    for i in range(4):
        x, y = src[i]
        u, v = q[i]
        rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
        rhs.append(u)
        rows.append([0, 0, 0, x, y, 1, -v * x, -v * y])
        rhs.append(v)
    s = solve(rows, rhs)
    return None if s is None else s + [1.0]


def kinv_norm(h, col, cx, cy, f):
    gx, gy, gw = h[col], h[3 + col], h[6 + col]
    x = (gx - cx * gw) / f
    y = (gy - cy * gw) / f
    norm = math.sqrt(x * x + y * y + gw * gw)
    return norm if math.isfinite(norm) and norm > 0 else None


def estimate(corners, sw, sh):
    if len(corners) != 4 or sw < 2 or sh < 2:
        return None
    sx, sy = float(sw - 1), float(sh - 1)
    q = [(c[0] * sx, c[1] * sy) for c in corners]
    wv = intersect(q[0], q[1], q[3], q[2])
    hv = intersect(q[0], q[3], q[1], q[2])
    if wv is None or hv is None:
        return None
    cx, cy = sx / 2, sy / 2
    f2 = -((wv[0] - cx) * (hv[0] - cx) + (wv[1] - cy) * (hv[1] - cy))
    if not (math.isfinite(f2) and f2 > 0):
        return None
    f = math.sqrt(f2)
    long_edge = float(max(sw, sh))
    if f < MIN_F * long_edge or f > MAX_F * long_edge:
        return None
    h = unit_square_homography(q)
    if h is None:
        return None
    g0 = kinv_norm(h, 0, cx, cy, f)
    g1 = kinv_norm(h, 1, cx, cy, f)
    if g0 is None or g1 is None or g1 == 0:
        return None
    a = g0 / g1
    if not (math.isfinite(a) and MIN_A <= a <= MAX_A):
        return None
    return a, f


def project_norm(w_mm, h_mm, tx, ty, tz, dist, f, w, h, offsets=None):
    r = mat_mul(mat_mul(rot_x(tx), rot_y(ty)), rot_z(tz))
    out = []
    planar = [(-w_mm / 2, -h_mm / 2), (w_mm / 2, -h_mm / 2), (w_mm / 2, h_mm / 2), (-w_mm / 2, h_mm / 2)]
    for i, (X, Y) in enumerate(planar):
        p0 = r[0][0] * X + r[0][1] * Y
        p1 = r[1][0] * X + r[1][1] * Y
        depth = r[2][0] * X + r[2][1] * Y + dist
        u = f * p0 / depth + w / 2
        v = f * p1 / depth + h / 2
        if offsets:
            u += offsets[i][0]
            v += offsets[i][1]
        out.append((u / (w - 1), v / (h - 1)))
    return out


def deg(d):
    return math.radians(d)


def case(label, w_mm, h_mm, tx, ty, tz, dist, f, sw, sh, offsets=None):
    corners = project_norm(w_mm, h_mm, deg(tx), deg(ty), deg(tz), dist, f, sw, sh, offsets)
    r = estimate(corners, sw, sh)
    if r is None:
        return {"case": label, "determinable": False}
    return {
        "case": label,
        "determinable": True,
        "error_percent": round((r[0] / (w_mm / h_mm) - 1) * 100, 4),
        "focal_px": round(r[1], 1),
    }


def main():
    results = []
    for w, h in [(85.6, 54.0), (210.0, 297.0), (125.0, 88.0), (100.0, 100.0), (54.0, 85.6)]:
        results.append(case(f"two-axis 25/25 {w}x{h} 3000x4000 f3500", w, h, 25, 25, 0, 170, 3500, 3000, 4000))
    for roll in [0, 10, 20, 30, 45]:
        results.append(case(f"two-axis 25/25 roll {roll} 85.6x54", 85.6, 54, 25, 25, roll, 170, 3500, 3000, 4000))
    for tx, ty in [(20, 20), (30, 30), (30, -30), (40, 25), (15, 35), (10, 45)]:
        results.append(case(f"asymmetric tilt {tx}/{ty} 85.6x54", 85.6, 54, tx, ty, 0, 170, 3500, 3000, 4000))
    for sw, sh, f in [(1200, 1600, 1400), (4000, 3000, 4500), (2000, 2000, 2200), (6000, 4000, 7000)]:
        results.append(case(f"sizes {sw}x{sh} f{f} 25/25", 85.6, 54, 25, 25, 0, 170, f, sw, sh))
    results.append(case("x-tilt only 30 (expect not determinable)", 85.6, 54, 30, 0, 0, 170, 3500, 3000, 4000))
    results.append(case("y-tilt only 30 (expect not determinable)", 85.6, 54, 0, 30, 0, 170, 3500, 3000, 4000))
    results.append(case("in-plane roll only 30 (expect not determinable)", 85.6, 54, 0, 0, 30, 170, 3500, 3000, 4000))
    pattern = [(2, -2), (-2, 2), (2, 2), (-2, -2)]
    results.append(case("fixed +-2px pattern, 30/30", 85.6, 54, 30, 30, 0, 170, 3500, 3000, 4000, pattern))
    results.append(case("fixed +-2px pattern, 40/25 roll 20", 85.6, 54, 40, 25, 20, 170, 3500, 3000, 4000, pattern))
    out = {
        "note": "Pure Python port of physical_aspect.dart. Not a Dart run; CI runs the Dart tests.",
        "results": results,
    }
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "physical_aspect_results.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    for r in results:
        print(r)


if __name__ == "__main__":
    main()
