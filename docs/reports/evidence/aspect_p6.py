# Phase 6 pure-geometry study of the aspect estimators used by the app.
# Synthetic planar cards only. No user image. Deterministic seeds.
import math

# ---------- linear algebra (pure python) ----------
def solve(A, b):
    n = len(A)
    M = [row[:] + [b[i]] for i, row in enumerate(A)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c]))
        M[c], M[p] = M[p], M[c]
        for r in range(n):
            if r != c and M[c][c] != 0:
                f = M[r][c] / M[c][c]
                for k in range(c, n + 1):
                    M[r][k] -= f * M[c][k]
    return [M[i][n] / M[i][i] for i in range(n)]


def homography(src, dst):
    # 8x8 DLT with h33 = 1
    A, b = [], []
    for (x, y), (u, v) in zip(src, dst):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.append(u)
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y]); b.append(v)
    h = solve(A, b) + [1.0]
    return [[h[0], h[1], h[2]], [h[3], h[4], h[5]], [h[6], h[7], h[8]]]


def mat(A, B):
    return [[sum(A[i][k] * B[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def rx(a):
    c, s = math.cos(a), math.sin(a)
    return [[1, 0, 0], [0, c, -s], [0, s, c]]


def ry(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]


def rz(a):
    c, s = math.cos(a), math.sin(a)
    return [[c, -s, 0], [s, c, 0], [0, 0, 1]]


# ---------- synthetic camera ----------
def make_scene(card_w, card_h, img_w, img_h, f, tilt_x=0.0, tilt_y=0.0, roll=0.0,
               centre_frac=(0.5, 0.5), span_max=0.6):
    """Normalised corners (TL,TR,BR,BL, app convention: pixel = norm*(size-1)), or None."""
    cx, cy = (img_w - 1) / 2, (img_h - 1) / 2
    K = [[f, 0, cx], [0, f, cy], [0, 0, 1]]
    R = mat(mat(rx(tilt_x), ry(tilt_y)), rz(roll))
    plane = [(0, 0), (card_w, 0), (card_w, card_h), (0, card_h)]

    def project(t, X, Y):
        Xc = [R[i][0] * X + R[i][1] * Y + t[i] for i in range(3)]
        p = [sum(K[i][k] * Xc[k] for k in range(3)) for i in range(3)]
        return (p[0] / p[2], p[1] / p[2])

    for dist in [x * 2.0 for x in range(10, 2000)]:
        t0 = [-card_w / 2, -card_h / 2, dist]
        pts0 = [project(t0, X, Y) for X, Y in plane]
        mx = sum(p[0] for p in pts0) / 4
        my = sum(p[1] for p in pts0) / 4
        dx = (centre_frac[0] * (img_w - 1) - mx) * dist / f
        dy = (centre_frac[1] * (img_h - 1) - my) * dist / f
        t = [t0[0] + dx, t0[1] + dy, dist]
        pts = [project(t, X, Y) for X, Y in plane]
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        fits = min(xs) >= 0 and max(xs) <= img_w - 1 and min(ys) >= 0 and max(ys) <= img_h - 1
        span = (max(xs) - min(xs)) / img_w
        if fits and span <= span_max:
            return [(x / (img_w - 1), y / (img_h - 1)) for x, y in pts]
    return None


# ---------- estimators ----------
def dist_px(a, b, W, H):
    return math.hypot((a[0] - b[0]) * (W - 1), (a[1] - b[1]) * (H - 1))


def assess_quad_aspect(q, W, H):
    """Mirror of assessQuad aspect + geometryConfidence (quad_assessment.dart ~100-163)."""
    px = [p[0] * (W - 1) for p in q]
    py = [p[1] * (H - 1) for p in q]
    top = dist_px(q[0], q[1], W, H)
    bottom = dist_px(q[3], q[2], W, H)
    left = dist_px(q[0], q[3], W, H)
    right = dist_px(q[1], q[2], W, H)
    hr = max(top, bottom) / min(top, bottom)
    vr = max(left, right) / min(left, right)
    width = (top + bottom) / 2
    height = (left + right) / 2
    aspect = max(width, height) / min(width, height)
    twice = 0.0
    for i in range(4):
        j = (i + 1) % 4
        twice += px[i] * py[j] - px[j] * py[i]
    area_frac = (abs(twice) / 2) / ((W - 1) * (H - 1))
    angle_score = 1.0
    for i in range(4):
        pr = (i + 3) % 4
        nx = (i + 1) % 4
        v1 = (px[pr] - px[i], py[pr] - py[i])
        v2 = (px[nx] - px[i], py[nx] - py[i])
        c = (v1[0] * v2[0] + v1[1] * v2[1]) / (math.hypot(*v1) * math.hypot(*v2))
        ang = math.degrees(math.acos(max(-1.0, min(1.0, c))))
        angle_score = min(angle_score, max(0.0, min(1.0, 1 - abs(ang - 90) / 45)))
    edge_score = max(0.0, min(1.0, 1 - (max(hr, vr) - 1) / 1.5))
    area_score = max(0.0, min(1.0, area_frac / 0.15))
    conf = max(0.0, min(1.0, 0.5 * angle_score + 0.3 * edge_score + 0.2 * area_score))
    accepted = (area_frac >= 0.02 and min(top, bottom, left, right) >= 4
                and hr <= 2.5 and vr <= 2.5 and aspect <= 12)
    return aspect, conf, accepted, angle_score


def torecipe_aspect(q, W, H):
    """Mirror of CropDraft.toRecipe output sizing before scale/floor (crop_draft.dart 66-101)."""
    w = (dist_px(q[0], q[1], W, H) + dist_px(q[3], q[2], W, H)) / 2 + 1
    h = (dist_px(q[0], q[3], W, H) + dist_px(q[1], q[2], W, H)) / 2 + 1
    return max(w, h) / min(w, h)


def metric_aspect(q, W, H, f=None):
    """Homography alternative. unit square -> pixels; principal point at centre.
    Metric aspect = |K^-1 h1| / |K^-1 h2|. If f is None, f is estimated from c1 . c2 = 0."""
    pts = [(p[0] * (W - 1), p[1] * (H - 1)) for p in q]
    Hm = homography([(0, 0), (1, 0), (1, 1), (0, 1)], pts)
    h1 = [Hm[r][0] for r in range(3)]
    h2 = [Hm[r][1] for r in range(3)]
    cx, cy = (W - 1) / 2, (H - 1) / 2
    if f is None:
        p1 = (h1[0] - cx * h1[2], h1[1] - cy * h1[2])
        p2 = (h2[0] - cx * h2[2], h2[1] - cy * h2[2])
        dot = p1[0] * p2[0] + p1[1] * p2[1]
        denom = h1[2] * h2[2]
        if abs(denom) < 1e-9 * max(1.0, abs(dot)):
            # Orthogonality gives 0 = dot/f^2 + 0: f is not observable from this
            # quad (no perspective in one axis, or none at all). Report it as
            # unobservable and let the caller supply an assumed f.
            return None, None
        f2 = -dot / denom
        if f2 <= 0:
            return None, None
        f = math.sqrt(f2)

    def kinv(h):
        return [(h[0] - cx * h[2]) / f, (h[1] - cy * h[2]) / f, h[2]]

    c1 = kinv(h1)
    c2 = kinv(h2)
    n1 = math.sqrt(sum(v * v for v in c1))
    n2 = math.sqrt(sum(v * v for v in c2))
    a = n1 / n2
    return max(a, 1 / a), f
