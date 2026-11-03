"""Python port of canonicalQuadCorners start-edge selection (lib/domain/geometry.dart).

Evidence only: this is NOT the Dart implementation. It exists to decide P1
(keep the 1.15 length weight or use pure cosine heading) from data.

Rules compared:
  weight115: score = dx + 1.15 * len / maxLen   (current code)
  pureCos:   score = dx                          (cosine heading only)
Both skip edges with dx <= 0 and fall back to start=0 when none qualifies.

Ground truth. Upright documents: a rectangle of aspect A rotated by theta with
perspective. For theta in [-45, 45] the document's own top-left corner is the
unambiguous canonical TL, because its top edge heading lies in [-45, 45].
Outside that range the convention itself is ambiguous (landscape vs portrait),
so the sweep reports it separately and does not count it as an error.
"""
import math, random, json, sys

def canonical(points, rule):
    cx = sum(p[0] for p in points) / 4
    cy = sum(p[1] for p in points) / 4
    srt = sorted(points, key=lambda p: math.atan2(p[1] - cy, p[0] - cx))
    twice = 0.0
    for i in range(4):
        a, b = srt[i], srt[(i + 1) % 4]
        twice += a[0] * b[1] - b[0] * a[1]
    ordered = srt[::-1] if twice < 0 else srt
    lengths = [math.hypot(ordered[(i + 1) % 4][0] - ordered[i][0],
                          ordered[(i + 1) % 4][1] - ordered[i][1]) for i in range(4)]
    max_len = max(1e-6, max(lengths))
    start, best = 0, -math.inf
    for i in range(4):
        a, b = ordered[i], ordered[(i + 1) % 4]
        ln = lengths[i]
        if ln <= 0:
            continue
        dx = (b[0] - a[0]) / ln
        if dx <= 0:
            continue
        score = dx + (1.15 * (ln / max_len) if rule == "weight115" else 0.0)
        if score > best:
            best, start = score, i
    return [ordered[(start + i) % 4] for i in range(4)], start

def doc_quad(cx, cy, w, h, theta_deg, persp):
    """Rectangle corners TL,TR,BR,BL in document frame, rotated and perspective-warped."""
    t = math.radians(theta_deg)
    corners = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
    out = []
    for (x, y) in corners:
        xr = x * math.cos(t) - y * math.sin(t)
        yr = x * math.sin(t) + y * math.cos(t)
        # simple projective warp: divide by (1 + g*x + f*y)
        g, f = persp
        d = 1 + g * xr + f * yr
        out.append((cx + xr / d, cy + yr / d))
    return out

def run(samples, seed=7):
    rng = random.Random(seed)
    res = {"upright_cases": 0, "w115_wrong_upright": 0, "pure_wrong_upright": 0,
           "disagree_all": 0, "total": 0, "worst": None, "examples": []}
    aspects = [1.0, 1.29, 1.586, 2.0]
    for k in range(samples):
        A = rng.choice(aspects)
        w, h = 100.0 * A, 100.0
        theta = rng.uniform(-90, 90) if k % 2 else rng.uniform(-45, 45)
        persp = (rng.uniform(-0.004, 0.004), rng.uniform(-0.004, 0.004)) if k % 3 == 0 else (0.0, 0.0)
        pts = doc_quad(0, 0, w, h, theta, persp)
        # permute input order randomly (taps arrive in any order)
        perm = pts[:]
        rng.shuffle(perm)
        res["total"] += 1
        q115, s115 = canonical(perm, "weight115")
        qcos, scos = canonical(perm, "pureCos")
        # identify which doc corner each output TL is
        def doc_index(p):
            return min(range(4), key=lambda i: (pts[i][0] - p[0]) ** 2 + (pts[i][1] - p[1]) ** 2)
        i115 = doc_index(q115[0]); icos = doc_index(qcos[0])
        if i115 != icos:
            res["disagree_all"] += 1
        if -45 <= theta <= 45:
            res["upright_cases"] += 1
            if i115 != 0:
                res["w115_wrong_upright"] += 1
                if res["worst"] is None or abs(theta) > abs(res["worst"]["theta"]):
                    res["worst"] = {"theta": round(theta, 2), "aspect": A, "persp": persp, "doc_index_chosen": i115}
                if len(res["examples"]) < 3:
                    res["examples"].append({"theta": round(theta, 2), "aspect": A, "persp": [round(v, 5) for v in persp]})
            if icos != 0:
                res["pure_wrong_upright"] += 1
    return res

if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    out = run(n)
    print(json.dumps(out, indent=2, ensure_ascii=False))


def bucketed(n_per_seed=20000, seeds=(7, 11, 23)):
    """Bucket by |theta| so the 45-degree boundary is not counted as an error."""
    table = {}
    for seed in seeds:
        rng = random.Random(seed)
        for k in range(n_per_seed):
            A = rng.choice([1.0, 1.29, 1.586, 2.0])
            theta = rng.uniform(-45, 45)
            persp = (rng.uniform(-0.004, 0.004), rng.uniform(-0.004, 0.004)) if k % 3 == 0 else (0.0, 0.0)
            pts = doc_quad(0, 0, 100 * A, 100.0, theta, persp)
            perm = pts[:]
            rng.shuffle(perm)
            q115, _ = canonical(perm, "weight115")
            qc, _ = canonical(perm, "pureCos")
            di = lambda p: min(range(4), key=lambda i: (pts[i][0] - p[0]) ** 2 + (pts[i][1] - p[1]) ** 2)
            bucket = "abs_theta_le_30" if abs(theta) <= 30 else "abs_theta_30_to_45"
            d = table.setdefault(bucket, {"n": 0, "weight115_wrong": 0, "pureCos_wrong": 0, "rules_disagree": 0, "weight115_wrong_perspective": 0, "perspective_n": 0})
            d["n"] += 1
            if di(q115[0]) != 0:
                d["weight115_wrong"] += 1
                if persp != (0.0, 0.0):
                    d["weight115_wrong_perspective"] += 1
            if di(qc[0]) != 0:
                d["pureCos_wrong"] += 1
            if di(q115[0]) != di(qc[0]):
                d["rules_disagree"] += 1
            if persp != (0.0, 0.0):
                d["perspective_n"] += 1
    return table
