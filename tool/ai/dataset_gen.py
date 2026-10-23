"""Leak-free dataset & scene generator for two-stage document boundary AI.

Strict provenance & split rules:
1. Only permissively licensed real natural/scene photographs (`opencv` Apache-2.0,
   `scikit-image` BSD-3-Clause) and verified non-PII MIT specimen templates
   (`PassportEye` official SPECIMEN/UTO/PUBLIC<<JON) plus first-party procedural
   cards/documents are used. No web-crawled pools, no AGPL/non-commercial data,
   and no personal citizen PII.
2. Every external background or specimen template is deduplicated by SHA-256 and
   64-bit dHash (Hamming distance <= 10 grouped into the same equivalence class)
   and deterministically assigned to ONE split (`train`, `val`, or `test`) BEFORE
   any augmentation or scene composition.
3. Procedural specimen generators also use disjoint seed namespaces per split:
   - `train`: base seed 100_000+
   - `val`:   base seed 500_000+
   - `test`:  base seed 900_000+
"""

from __future__ import annotations

import glob
import hashlib
import math
import os
from dataclasses import dataclass
from typing import Literal

import cv2
import numpy as np
from PIL import Image, ImageOps

SplitName = Literal["train", "val", "test"]

# Catalog aspect ratios (width / height in canonical landscape or portrait)
CATALOG_SPECS: list[tuple[str, float, bool]] = [
    ("unified_id", 85.60 / 53.98, True),      # 1.5858 rounded plastic
    ("residence_card", 92.40 / 62.80, True),  # 1.4713 rounded plastic
    ("passport_page", 125.0 / 88.0, True),    # 1.4205 passport booklet/page
    ("ration_card", 287.0 / 52.0, False),     # 5.5192 Iraqi ration form
    ("a4_sheet", 297.0 / 210.0, False),       # 1.4142 paper sheet
    ("receipt_note", 210.0 / 110.0, False),   # 1.9091 bill / note / receipt
    ("index_card", 127.0 / 76.2, False),      # 1.6667 card / note
]


def compute_dhash(rgb: np.ndarray, size: int = 8) -> int:
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    small = cv2.resize(gray, (size + 1, size), interpolation=cv2.INTER_AREA)
    bits = (small[:, 1:] > small[:, :-1]).flatten()
    val = 0
    for b in bits:
        val = (val << 1) | int(bool(b))
    return val


def hamming64(a: int, b: int) -> int:
    return (a ^ b).bit_count()


@dataclass(frozen=True)
class SourceAsset:
    asset_id: str
    rgb: np.ndarray
    license_spdx: str
    origin: str
    sha256: str
    dhash: int
    split: SplitName


def _assign_group_split(group_key: str) -> SplitName:
    bucket = int(hashlib.sha256(group_key.encode("utf-8")).hexdigest()[:8], 16) % 100
    if bucket < 68:
        return "train"
    if bucket < 84:
        return "val"
    return "test"


def load_disjoint_background_pools(
    opencv_dir: str = "/tmp/inspect_data/opencv_samples",
) -> dict[SplitName, list[SourceAsset]]:
    """Load real natural/indoor photos from skimage (BSD-3) & OpenCV (Apache-2.0)
    with near-duplicate clustering so splits share zero source scenes."""
    raw_items: list[tuple[str, np.ndarray, str, str, str, int]] = []

    # 1. scikit-image BSD-3-Clause real photos (exclude document-like `page`)
    try:
        import skimage.data as skdata

        sk_names = [
            "astronaut",
            "camera",
            "cat",
            "chelsea",
            "coffee",
            "coins",
            "grass",
            "gravel",
            "brick",
            "immunohistochemistry",
            "retina",
            "rocket",
        ]
        for name in sk_names:
            if not hasattr(skdata, name):
                continue
            arr = getattr(skdata, name)()
            if isinstance(arr, tuple):
                arr = arr[0]
            if arr.ndim == 2:
                arr = cv2.cvtColor(arr, cv2.COLOR_GRAY2RGB)
            elif arr.shape[2] == 4:
                arr = arr[:, :, :3]
            arr = np.ascontiguousarray(arr, dtype=np.uint8)
            sha = hashlib.sha256(arr.tobytes()).hexdigest()
            raw_items.append(
                (f"skimage_{name}", arr, "BSD-3-Clause", "scikit-image", sha, compute_dhash(arr))
            )
    except ImportError:
        pass

    # 2. OpenCV samples/data Apache-2.0 real photos (exclude cards/notes/sudoku)
    excluded_opencv = {"cards.png", "sudoku.png", "imageTextN.png", "imageTextR.png", "text_defocus.jpg", "text_motion.jpg"}
    if os.path.isdir(opencv_dir):
        for path in sorted(glob.glob(os.path.join(opencv_dir, "*"))):
            fname = os.path.basename(path)
            if fname in excluded_opencv or not os.path.isfile(path):
                continue
            try:
                with open(path, "rb") as fh:
                    raw_bytes = fh.read()
                if len(raw_bytes) < 1024:
                    continue
                with Image.open(path) as raw_im:
                    im = ImageOps.exif_transpose(raw_im).convert("RGB")
                arr = np.ascontiguousarray(np.array(im), dtype=np.uint8)
                if min(arr.shape[:2]) < 160:
                    continue
                sha = hashlib.sha256(raw_bytes).hexdigest()
                raw_items.append(
                    (f"opencv_{fname}", arr, "Apache-2.0", "opencv/samples", sha, compute_dhash(arr))
                )
            except Exception:
                continue

    # Cluster near-duplicates (dHash Hamming <= 10) before assigning splits!
    parent = list(range(len(raw_items)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(len(raw_items)):
        for j in range(i + 1, len(raw_items)):
            if raw_items[i][4] == raw_items[j][4] or hamming64(raw_items[i][5], raw_items[j][5]) <= 10:
                ri, rj = find(i), find(j)
                if ri != rj:
                    parent[rj] = ri

    pools: dict[SplitName, list[SourceAsset]] = {"train": [], "val": [], "test": []}
    for idx, (aid, arr, lic, origin, sha, dh) in enumerate(raw_items):
        rep_sha = raw_items[find(idx)][4]
        split = _assign_group_split("bg_" + rep_sha)
        pools[split].append(
            SourceAsset(
                asset_id=aid,
                rgb=arr,
                license_spdx=lic,
                origin=origin,
                sha256=sha,
                dhash=dh,
                split=split,
            )
        )
    return pools


def load_disjoint_specimen_pools(
    passporteye_dir: str = "/tmp/inspect_data/PassportEye-master/passporteye/mrz/testdata",
) -> dict[SplitName, list[SourceAsset]]:
    """Load MIT-licensed specimen card/passport templates from PassportEye,
    strictly excluding any wild camera test scene (`62_pass-aus.png`, `100_pass-lux.jpg`,
    `0_pass-lva.jpg`) and clustering near-duplicates before split assignment."""
    heldout_wild_names = {"62_pass-aus.png", "100_pass-lux.jpg", "0_pass-lva.jpg"}
    raw_items: list[tuple[str, np.ndarray, str, str, str, int]] = []
    if os.path.isdir(passporteye_dir):
        for path in sorted(glob.glob(os.path.join(passporteye_dir, "*"))):
            fname = os.path.basename(path)
            if fname in heldout_wild_names or not os.path.isfile(path):
                continue
            try:
                with open(path, "rb") as fh:
                    raw_bytes = fh.read()
                with Image.open(path) as raw_im:
                    im = ImageOps.exif_transpose(raw_im).convert("RGB")
                arr = np.ascontiguousarray(np.array(im), dtype=np.uint8)
                if min(arr.shape[:2]) < 140:
                    continue
                sha = hashlib.sha256(raw_bytes).hexdigest()
                raw_items.append(
                    (f"pe_{fname}", arr, "MIT", "PassportEye", sha, compute_dhash(arr))
                )
            except Exception:
                continue

    parent = list(range(len(raw_items)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(len(raw_items)):
        for j in range(i + 1, len(raw_items)):
            if raw_items[i][4] == raw_items[j][4] or hamming64(raw_items[i][5], raw_items[j][5]) <= 10:
                ri, rj = find(i), find(j)
                if ri != rj:
                    parent[rj] = ri

    pools: dict[SplitName, list[SourceAsset]] = {"train": [], "val": [], "test": []}
    for idx, (aid, arr, lic, origin, sha, dh) in enumerate(raw_items):
        rep_sha = raw_items[find(idx)][4]
        split = _assign_group_split("spec_" + rep_sha)
        pools[split].append(
            SourceAsset(
                asset_id=aid,
                rgb=arr,
                license_spdx=lic,
                origin=origin,
                sha256=sha,
                dhash=dh,
                split=split,
            )
        )
    return pools


def canonicalize_quad_clockwise_tl(pts: np.ndarray) -> np.ndarray:
    """Order 4 points clockwise in y-down image coords starting at top-left."""
    pts = np.asarray(pts, dtype=np.float32).reshape(4, 2)
    center = pts.mean(axis=0)
    angles = np.arctan2(pts[:, 1] - center[1], pts[:, 0] - center[0])
    order = np.argsort(angles)  # ascending atan2 in y-down is clockwise!
    ordered = pts[order]
    # Signed area in y-down (> 0 means clockwise)
    x, y = ordered[:, 0], ordered[:, 1]
    area2 = float(np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y))
    if area2 < 0:
        ordered = ordered[::-1]
    # Top-left: smallest (x + y), breaking ties by smallest y
    sums = ordered[:, 0] + ordered[:, 1]
    start = int(np.argmin(sums))
    return np.roll(ordered, -start, axis=0)


def polygon_area(poly: np.ndarray) -> float:
    if len(poly) < 3:
        return 0.0
    x, y = poly[:, 0], poly[:, 1]
    return 0.5 * abs(float(np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y)))


def clip_convex_polygon(subject: np.ndarray, clipper: np.ndarray) -> np.ndarray:
    """Sutherland-Hodgman clipping for clockwise convex polygons in y-down coords."""
    output = [tuple(p) for p in subject]
    n_clip = len(clipper)
    for i in range(n_clip):
        if not output:
            return np.zeros((0, 2), dtype=np.float32)
        ax, ay = clipper[i]
        bx, by = clipper[(i + 1) % n_clip]
        ex, ey = bx - ax, by - ay

        def inside(pt: tuple[float, float]) -> bool:
            # For clockwise polygon in y-down, interior lies on right-hand side:
            # ex * (py - ay) - ey * (px - ax) >= -1e-7
            return (ex * (pt[1] - ay) - ey * (pt[0] - ax)) >= -1e-7

        def intersect(p1: tuple[float, float], p2: tuple[float, float]) -> tuple[float, float]:
            dx, dy = p2[0] - p1[0], p2[1] - p1[1]
            denom = ex * dy - ey * dx
            if abs(denom) < 1e-12:
                return p2
            t = (ex * (ay - p1[1]) - ey * (ax - p1[0])) / denom
            t = max(0.0, min(1.0, t))
            return (p1[0] + t * dx, p1[1] + t * dy)

        inp = output
        output = []
        s = inp[-1]
        for e in inp:
            if inside(e):
                if not inside(s):
                    output.append(intersect(s, e))
                output.append(e)
            elif inside(s):
                output.append(intersect(s, e))
            s = e
    return np.array(output, dtype=np.float32)


def polygon_iou(q1: np.ndarray, q2: np.ndarray) -> float:
    p1 = canonicalize_quad_clockwise_tl(q1)
    p2 = canonicalize_quad_clockwise_tl(q2)
    inter = clip_convex_polygon(p1, p2)
    inter_area = polygon_area(inter)
    if inter_area <= 0.0:
        return 0.0
    union = polygon_area(p1) + polygon_area(p2) - inter_area
    return inter_area / max(union, 1e-9)


def render_procedural_background(
    rng: np.random.Generator,
    width: int,
    height: int,
    bg_pool: list[SourceAsset],
) -> np.ndarray:
    """Synthesize diverse desks, wood, fabric, stone, laptop bezels, or real crops."""
    mode = int(rng.integers(0, 6))
    if mode in (0, 1) and bg_pool:
        src = bg_pool[int(rng.integers(0, len(bg_pool)))].rgb
        sh, sw = src.shape[:2]
        scale = float(rng.uniform(0.55, 1.0))
        cw = max(64, int(sw * scale))
        ch = max(64, int(sh * scale))
        x0 = int(rng.integers(0, max(1, sw - cw + 1)))
        y0 = int(rng.integers(0, max(1, sh - ch + 1)))
        crop = src[y0 : y0 + ch, x0 : x0 + cw]
        if rng.random() < 0.5:
            crop = np.fliplr(crop)
        if rng.random() < 0.5:
            crop = np.flipud(crop)
        bg = cv2.resize(crop, (width, height), interpolation=cv2.INTER_LINEAR)
        # Random color/exposure shift so texture stays realistic & varied
        gain = rng.uniform(0.55, 1.25, size=(1, 1, 3)).astype(np.float32)
        bias = rng.uniform(-25.0, 25.0, size=(1, 1, 3)).astype(np.float32)
        bg = np.clip(bg.astype(np.float32) * gain + bias, 0, 255).astype(np.uint8)
    elif mode == 2:
        # Realistic wood grain desk with planks
        base = rng.uniform([85, 55, 35], [195, 165, 130]).astype(np.float32)
        xs = np.linspace(0, rng.uniform(4.0, 14.0), width, dtype=np.float32)[None, :]
        ys = np.linspace(0, rng.uniform(4.0, 14.0), height, dtype=np.float32)[:, None]
        if rng.random() < 0.5:
            xs, ys = ys, xs
        wave = np.sin(xs * 3.1 + np.sin(ys * 1.7) * 2.2) * 0.5 + 0.5
        fine = rng.normal(0, 6.0, size=(height, width)).astype(np.float32)
        grain = (wave * rng.uniform(12.0, 36.0) + fine)[:, :, None]
        bg = np.clip(base[None, None, :] + grain * np.array([1.0, 0.78, 0.55], dtype=np.float32), 0, 255).astype(np.uint8)
        if rng.random() < 0.45:
            # Wood plank seam lines
            for pos in range(int(rng.integers(40, 110)), height, int(rng.integers(80, 170))):
                cv2.line(bg, (0, pos), (width, pos), tuple(int(max(0, c - 30)) for c in base), 1)
    elif mode == 3:
        # Matte desk / school table / granite / dark cloth
        base = rng.uniform([22, 22, 25], [205, 198, 185]).astype(np.float32)
        speckle = rng.normal(0, rng.uniform(3.0, 16.0), size=(height, width, 3)).astype(np.float32)
        speckle = cv2.GaussianBlur(speckle, (3, 3), 0.8)
        bg = np.clip(base[None, None, :] + speckle, 0, 255).astype(np.uint8)
    elif mode == 4:
        # Woven fabric / carpet / grid mat
        base = rng.uniform([35, 40, 48], [175, 170, 165]).astype(np.float32)
        bg_f = np.broadcast_to(base, (height, width, 3)).copy()
        period = int(rng.integers(4, 14))
        yy, xx = np.mgrid[0:height, 0:width]
        weave = ((np.sin(xx * (2 * math.pi / period)) + np.sin(yy * (2 * math.pi / period))) * rng.uniform(4.0, 14.0))[:, :, None]
        bg = np.clip(bg_f + weave, 0, 255).astype(np.uint8)
    else:
        # Desk with non-document clutter (laptop edge, cables, shadow bands, pens)
        base = rng.uniform([45, 48, 52], [185, 178, 165]).astype(np.float32)
        bg = np.clip(
            base[None, None, :] + rng.normal(0, 6.0, size=(height, width, 3)),
            0,
            255,
        ).astype(np.uint8)

    # Optionally add ambient desk distractors (soft shadow band, cable, edge bezel)
    if rng.random() < 0.35:
        overlay = bg.copy()
        if rng.random() < 0.5:
            # Semi-transparent shadow band (teaches model shadow != opaque card!)
            x1 = int(rng.integers(0, width - 20))
            w_band = int(rng.integers(12, max(20, width // 5)))
            y1 = int(rng.integers(0, height // 3))
            y2 = int(rng.integers(height * 2 // 3, height))
            mask = np.zeros((height, width), dtype=np.float32)
            cv2.rectangle(mask, (x1, y1), (min(width - 1, x1 + w_band), y2), 1.0, -1)
            mask = cv2.GaussianBlur(mask, (15, 15), 5.0)
            factor = float(rng.uniform(0.50, 0.80))
            bg = np.clip(bg.astype(np.float32) * (1.0 - (1.0 - factor) * mask[:, :, None]), 0, 255).astype(np.uint8)
        else:
            # Cable or pen line
            p1 = (int(rng.integers(0, width)), int(rng.integers(0, height)))
            p2 = (int(rng.integers(0, width)), int(rng.integers(0, height)))
            col = tuple(int(x) for x in rng.integers(15, 90, size=3))
            cv2.line(overlay, p1, p2, col, int(rng.integers(2, 7)), lineType=cv2.LINE_AA)
            bg = overlay
    return bg


def render_specimen_card_texture(
    rng: np.random.Generator,
    kind_name: str,
    aspect: float,
    rounded: bool,
    bg_mean_luma: float,
    specimen_pool: list[SourceAsset] | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    """Render a clean-room synthetic or MIT specimen card/document RGBA."""
    if specimen_pool and kind_name in ("unified_id", "residence_card", "passport_page") and rng.random() < 0.30:
        src = specimen_pool[int(rng.integers(0, len(specimen_pool)))].rgb
        if rng.random() < 0.35:
            src = np.rot90(src, k=int(rng.choice([1, 2, 3]))).copy()
        ch, cw = src.shape[:2]
        # Scale to clean working size
        scale = 280.0 / max(ch, cw)
        cw = max(64, int(round(cw * scale)))
        ch = max(64, int(round(ch * scale)))
        tex = cv2.resize(src, (cw, ch), interpolation=cv2.INTER_LINEAR)
        gain = float(rng.uniform(0.82, 1.12))
        bias = float(rng.uniform(-14.0, 14.0))
        tex = np.clip(tex.astype(np.float32) * gain + bias, 0, 255).astype(np.uint8)
        alpha = np.full((ch, cw), 255, dtype=np.uint8)
        if rounded and rng.random() < 0.7:
            alpha.fill(0)
            rad = max(3, int(min(cw, ch) * 0.045))
            cv2.rectangle(alpha, (rad, 0), (cw - rad, ch), 255, -1)
            cv2.rectangle(alpha, (0, rad), (cw, ch - rad), 255, -1)
            for cx_r, cy_r in [(rad, rad), (cw - rad - 1, rad), (cw - rad - 1, ch - rad - 1), (rad, ch - rad - 1)]:
                cv2.circle(alpha, (cx_r, cy_r), rad, 255, -1, lineType=cv2.LINE_AA)
        return tex, alpha

    portrait = bool(rng.random() < 0.45)
    eff_aspect = (1.0 / aspect) if portrait else aspect
    long_px = 340 if max(eff_aspect, 1.0 / eff_aspect) > 3.0 else 260
    if eff_aspect >= 1.0:
        cw = long_px
        ch = max(48, int(round(long_px / eff_aspect)))
    else:
        ch = long_px
        cw = max(48, int(round(long_px * eff_aspect)))

    # Choose card substrate color ensuring realistic variety (including low-contrast & dark cards!)
    style_roll = float(rng.random())
    if style_roll < 0.14:
        # Dark passport cover / dark card
        base_col = rng.uniform([24, 30, 48], [72, 65, 80])
        if bg_mean_luma < 75:
            base_col = rng.uniform([195, 198, 205], [245, 244, 238])
        ink_col = rng.uniform([185, 175, 120], [235, 225, 185])
    elif style_roll < 0.32:
        # Low-contrast cream/beige/tinted card relative to desk (minimum |dL| >= 22)
        delta = float(rng.choice([-1.0, 1.0])) * float(rng.uniform(24.0, 45.0))
        target_l = float(np.clip(bg_mean_luma + delta, 28.0, 242.0))
        if abs(target_l - bg_mean_luma) < 22.0:
            target_l = float(np.clip(bg_mean_luma + (32.0 if bg_mean_luma < 128 else -32.0), 25.0, 245.0))
        tint = rng.uniform(-10.0, 12.0, size=3)
        base_col = np.clip(target_l + tint, 20, 248)
        ink_col = np.clip(base_col - rng.uniform(75, 145), 15, 210) if target_l > 95 else np.clip(base_col + 110, 140, 240)
    else:
        # Typical white / off-white / pastel ID-1 / green-blue security tint
        base_col = rng.uniform([198, 202, 196], [250, 249, 244])
        if bg_mean_luma > 205:
            base_col = rng.uniform([145, 155, 165], [182, 185, 190])
        ink_col = rng.uniform([25, 28, 35], [85, 88, 98])

    tex = np.broadcast_to(base_col.astype(np.float32), (ch, cw, 3)).copy()
    tex += rng.normal(0, 2.5, size=(ch, cw, 3)).astype(np.float32)

    # Security guilloche / subtle wave background for IDs & passports
    if kind_name in ("unified_id", "residence_card", "passport_page") and rng.random() < 0.75:
        yy, xx = np.mgrid[0:ch, 0:cw].astype(np.float32)
        pat = np.sin(xx * 0.14 + np.sin(yy * 0.09) * 2.5) * rng.uniform(3.0, 8.0)
        tex[:, :, 1] += pat
        tex[:, :, 2] += pat * 0.7
    tex = np.clip(tex, 0, 255).astype(np.uint8)

    ink = tuple(int(c) for c in ink_col)
    doc_layout = float(rng.random())

    if doc_layout < 0.25:
        # Sparse note / sketch / back-of-card style (few strokes or sparse text, no colored banner)
        for _ in range(int(rng.integers(2, 8))):
            pts_curve = np.column_stack(
                [
                    np.linspace(cw * rng.uniform(0.1, 0.3), cw * rng.uniform(0.5, 0.9), 8),
                    cw * 0.0 + rng.uniform(ch * 0.15, ch * 0.85) + rng.normal(0, ch * 0.04, size=8),
                ]
            ).astype(np.int32)
            cv2.polylines(tex, [pts_curve], False, ink, int(rng.integers(1, 4)), lineType=cv2.LINE_AA)
    else:
        # Header band on ID/forms
        if kind_name not in ("a4_sheet", "index_card") and rng.random() < 0.68:
            hdr_h = max(6, int(ch * rng.uniform(0.08, 0.16)))
            hdr_col = tuple(int(np.clip(c, 15, 230)) for c in rng.uniform(35, 185, size=3))
            cv2.rectangle(tex, (int(cw * 0.04), int(ch * 0.04)), (int(cw * 0.96), int(ch * 0.04) + hdr_h), hdr_col, -1)

        # Portrait box on ID/Passport
        if kind_name in ("unified_id", "residence_card", "passport_page") and cw > ch and rng.random() < 0.78:
            pw = int(cw * rng.uniform(0.18, 0.26))
            ph = int(ch * rng.uniform(0.36, 0.52))
            px = int(cw * 0.06) if rng.random() < 0.6 else int(cw * 0.70)
            py = int(ch * rng.uniform(0.22, 0.34))
            pcol = tuple(int(c) for c in rng.integers(75, 175, size=3))
            cv2.rectangle(tex, (px, py), (min(cw - 4, px + pw), min(ch - 4, py + ph)), pcol, -1)
            cx_p, cy_p = px + pw // 2, py + ph // 3
            cv2.circle(tex, (cx_p, cy_p), max(4, pw // 5), ink, -1)
            cv2.ellipse(tex, (cx_p, py + int(ph * 0.82)), (max(6, pw // 3), max(5, ph // 4)), 0, 180, 360, ink, -1)

        # Text lines / table grids (ration card or paper sheet or MRZ)
        n_lines = int(rng.integers(5, 22)) if doc_layout > 0.70 else int(rng.integers(3, 12))
        for _ in range(n_lines):
            ly = int(rng.integers(int(ch * 0.10), max(int(ch * 0.12) + 1, int(ch * 0.94))))
            lx1 = int(rng.integers(int(cw * 0.05), int(cw * 0.45)))
            lx2 = int(rng.integers(min(cw - 6, lx1 + 12), max(min(cw - 5, lx1 + 13), int(cw * 0.95))))
            thick = int(rng.integers(1, 3))
            cv2.line(tex, (lx1, ly), (lx2, ly), ink, thick)

        if kind_name == "ration_card" or rng.random() < 0.28:
            gx1, gy1 = int(cw * 0.08), int(ch * 0.24)
            gx2, gy2 = int(cw * 0.92), int(ch * 0.86)
            if gx2 > gx1 + 16 and gy2 > gy1 + 16:
                cv2.rectangle(tex, (gx1, gy1), (gx2, gy2), ink, 1)
                for r in range(1, int(rng.integers(2, 5))):
                    ry = gy1 + (gy2 - gy1) * r // 4
                    cv2.line(tex, (gx1, ry), (gx2, ry), ink, 1)

    # Rounded vs sharp alpha mask
    alpha = np.zeros((ch, cw), dtype=np.uint8)
    if rounded and rng.random() < 0.85:
        rad = max(3, int(min(cw, ch) * rng.uniform(0.035, 0.065)))
        cv2.rectangle(alpha, (rad, 0), (cw - rad, ch), 255, -1)
        cv2.rectangle(alpha, (0, rad), (cw, ch - rad), 255, -1)
        for cx_r, cy_r in [(rad, rad), (cw - rad - 1, rad), (cw - rad - 1, ch - rad - 1), (rad, ch - rad - 1)]:
            cv2.circle(alpha, (cx_r, cy_r), rad, 255, -1, lineType=cv2.LINE_AA)
    else:
        alpha[:, :] = 255

    return tex, alpha


def sample_quad_homography(
    rng: np.random.Generator,
    aspect: float,
    img_w: int,
    img_h: int,
    area_range: tuple[float, float],
    max_persp: float = 0.22,
    allow_truncation: bool = False,
    force_truncated: bool = False,
) -> np.ndarray | None:
    """Sample a realistic 3D-projected quadrilateral in pixel coordinates [4, 2]."""
    portrait = bool(rng.random() < 0.45)
    eff_aspect = (1.0 / aspect) if portrait else aspect
    target_area = float(rng.uniform(area_range[0], area_range[1])) * (img_w * img_h)
    base_h = math.sqrt(target_area / eff_aspect)
    base_w = base_h * eff_aspect

    # Clamp so card fits when not truncated
    max_scale = min((img_w * 0.90) / max(base_w, 1.0), (img_h * 0.90) / max(base_h, 1.0))
    if not force_truncated and max_scale < 1.0:
        base_w *= max_scale
        base_h *= max_scale

    angle = float(rng.uniform(-math.pi, math.pi)) if rng.random() < 0.35 else float(rng.uniform(-0.52, 0.52))
    # Also include 90/180/270 camera orientations frequently
    if rng.random() < 0.35:
        angle += float(rng.choice([0.0, 0.5 * math.pi, -0.5 * math.pi, math.pi]))

    rect = np.array(
        [
            [-base_w * 0.5, -base_h * 0.5],
            [base_w * 0.5, -base_h * 0.5],
            [base_w * 0.5, base_h * 0.5],
            [-base_w * 0.5, base_h * 0.5],
        ],
        dtype=np.float32,
    )

    # Apply 3D foreshortening / trapezoid perspective + rotation
    taper_tb = float(rng.uniform(-max_persp, max_persp))
    taper_lr = float(rng.uniform(-max_persp, max_persp))
    rect[0, 0] *= 1.0 - taper_tb
    rect[1, 0] *= 1.0 - taper_tb
    rect[2, 0] *= 1.0 + taper_tb
    rect[3, 0] *= 1.0 + taper_tb

    rect[0, 1] *= 1.0 - taper_lr
    rect[3, 1] *= 1.0 - taper_lr
    rect[1, 1] *= 1.0 + taper_lr
    rect[2, 1] *= 1.0 + taper_lr

    ca, sa = math.cos(angle), math.sin(angle)
    rot = np.array([[ca, -sa], [sa, ca]], dtype=np.float32)
    pts = rect @ rot.T

    min_xy = pts.min(axis=0)
    max_xy = pts.max(axis=0)
    span_w, span_h = float(max_xy[0] - min_xy[0]), float(max_xy[1] - min_xy[1])

    if force_truncated:
        # Push 1 or 2 corners outside [0, img_w-1] x [0, img_h-1] while keeping >=55% inside
        side = int(rng.integers(0, 4))
        shift_frac = float(rng.uniform(0.08, 0.26))
        cx = float(rng.uniform(img_w * 0.30, img_w * 0.70))
        cy = float(rng.uniform(img_h * 0.30, img_h * 0.70))
        if side == 0:
            cx = -min_xy[0] - span_w * shift_frac
        elif side == 1:
            cx = (img_w - 1) - max_xy[0] + span_w * shift_frac
        elif side == 2:
            cy = -min_xy[1] - span_h * shift_frac
        else:
            cy = (img_h - 1) - max_xy[1] + span_h * shift_frac
        pts = pts + np.array([cx, cy], dtype=np.float32)
        return canonicalize_quad_clockwise_tl(pts)

    margin_x = max(5.0, img_w * 0.022)
    margin_y = max(5.0, img_h * 0.022)
    lo_x = margin_x - min_xy[0]
    hi_x = (img_w - 1 - margin_x) - max_xy[0]
    lo_y = margin_y - min_xy[1]
    hi_y = (img_h - 1 - margin_y) - max_xy[1]
    if lo_x > hi_x or lo_y > hi_y:
        if not allow_truncation:
            return None
        cx, cy = img_w * 0.5, img_h * 0.5
    else:
        cx = float(rng.uniform(lo_x, hi_x))
        cy = float(rng.uniform(lo_y, hi_y))
    pts = pts + np.array([cx, cy], dtype=np.float32)
    return canonicalize_quad_clockwise_tl(pts)


def warp_card_onto_scene(
    scene: np.ndarray,
    card_tex: np.ndarray,
    card_alpha: np.ndarray,
    quad_px: np.ndarray,
    rng: np.random.Generator,
) -> np.ndarray:
    """Projective warp of `card_tex` onto `scene` with soft cast drop-shadow."""
    h, w = scene.shape[:2]
    ch, cw = card_tex.shape[:2]
    src = np.array([[0, 0], [cw - 1, 0], [cw - 1, ch - 1], [0, ch - 1]], dtype=np.float32)
    H = cv2.getPerspectiveTransform(src, quad_px.astype(np.float32))

    # Soft cast shadow offset slightly
    sx = float(rng.uniform(-6.0, 9.0))
    sy = float(rng.uniform(2.0, 11.0))
    H_sh = cv2.getPerspectiveTransform(src, (quad_px + np.array([sx, sy], dtype=np.float32)))
    sh_mask = cv2.warpPerspective(card_alpha, H_sh, (w, h), flags=cv2.INTER_LINEAR).astype(np.float32) / 255.0
    kblur = int(rng.choice([5, 9, 13, 17]))
    sh_mask = cv2.GaussianBlur(sh_mask, (kblur, kblur), 0)
    sh_strength = float(rng.uniform(0.14, 0.42))
    out = scene.astype(np.float32) * (1.0 - sh_strength * sh_mask[:, :, None])

    warped_rgb = cv2.warpPerspective(card_tex, H, (w, h), flags=cv2.INTER_LINEAR).astype(np.float32)
    warped_a = cv2.warpPerspective(card_alpha, H, (w, h), flags=cv2.INTER_LINEAR).astype(np.float32) / 255.0
    out = out * (1.0 - warped_a[:, :, None]) + warped_rgb * warped_a[:, :, None]
    return np.clip(out, 0, 255).astype(np.uint8)


def apply_photometric_degradations(
    rgb: np.ndarray,
    rng: np.random.Generator,
    mode: str = "random",
) -> np.ndarray:
    """Apply realistic camera illumination, glare, low-light, blur, and JPEG noise."""
    out = rgb.astype(np.float32)
    h, w = out.shape[:2]

    # Smooth spatial lighting gradient
    if mode in ("random", "low_light", "glare") and rng.random() < 0.75:
        gx = np.linspace(rng.uniform(0.75, 1.15), rng.uniform(0.75, 1.15), w, dtype=np.float32)[None, :]
        gy = np.linspace(rng.uniform(0.75, 1.15), rng.uniform(0.75, 1.15), h, dtype=np.float32)[:, None]
        out *= (gx * gy)[:, :, None]

    # Specular laminate glare hotspot / reflection band
    if mode == "glare" or (mode == "random" and rng.random() < 0.25):
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        cx, cy = rng.uniform(0.2 * w, 0.8 * w), rng.uniform(0.2 * h, 0.8 * h)
        rx, ry = rng.uniform(0.08 * w, 0.28 * w), rng.uniform(0.06 * h, 0.22 * h)
        ang = rng.uniform(0, math.pi)
        u = (xx - cx) * math.cos(ang) + (yy - cy) * math.sin(ang)
        v = -(xx - cx) * math.sin(ang) + (yy - cy) * math.cos(ang)
        glare = np.exp(-0.5 * ((u / max(rx, 1.0)) ** 2 + (v / max(ry, 1.0)) ** 2))
        strength = float(rng.uniform(85.0, 165.0)) if mode == "glare" else float(rng.uniform(45.0, 125.0))
        out += glare[:, :, None] * strength

    # Low-light + ISO sensor noise
    if mode == "low_light" or (mode == "random" and rng.random() < 0.22):
        exposure = float(rng.uniform(0.38, 0.62)) if mode == "low_light" else float(rng.uniform(0.55, 0.85))
        sigma = float(rng.uniform(10.0, 22.0)) if mode == "low_light" else float(rng.uniform(4.0, 12.0))
        out = out * exposure + rng.normal(0.0, sigma, size=out.shape).astype(np.float32)

    out_u8 = np.clip(out, 0, 255).astype(np.uint8)

    # Defocus / directional motion blur
    if mode == "blur" or (mode == "random" and rng.random() < 0.22):
        if rng.random() < 0.55:
            ks = int(rng.choice([5, 7, 9])) if mode == "blur" else int(rng.choice([3, 5]))
            out_u8 = cv2.GaussianBlur(out_u8, (ks, ks), 0)
        else:
            ks = int(rng.choice([7, 9, 11])) if mode == "blur" else int(rng.choice([5, 7]))
            kern = np.zeros((ks, ks), dtype=np.float32)
            kern[ks // 2, :] = 1.0 / ks
            M = cv2.getRotationMatrix2D((ks / 2, ks / 2), float(rng.uniform(0, 180)), 1.0)
            kern = cv2.warpAffine(kern, M, (ks, ks))
            kern /= max(float(kern.sum()), 1e-6)
            out_u8 = cv2.filter2D(out_u8, -1, kern)

    # JPEG compression artifacts
    if rng.random() < 0.45:
        qual = int(rng.integers(48, 92))
        ok, enc = cv2.imencode(".jpg", out_u8, [int(cv2.IMWRITE_JPEG_QUALITY), qual])
        if ok:
            out_u8 = cv2.imdecode(enc, cv2.IMREAD_COLOR)

    return out_u8


def shrink_polygon_toward_centroid(quad: np.ndarray, ratio: float = 0.76) -> np.ndarray:
    c = quad.mean(axis=0, keepdims=True)
    return c + (quad - c) * ratio


def build_stage1_targets(
    quads_norm: list[np.ndarray],
    grid: int = 40,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Build Stage-1 targets:
    - dense_target [7, G, G]:
        ch 0: center_prob, ch 1: shrunk_mask (0.60x), ch 2: full_mask,
        ch 3..6: [xmin - cx, ymin - cy, xmax - cx, ymax - cy] instance extent offsets
    - reg_weight   [1, G, G]
    - scene_target [2] ([has_doc, is_multi])
    """
    dense = np.zeros((7, grid, grid), dtype=np.float32)
    reg_w = np.zeros((1, grid, grid), dtype=np.float32)

    valid_quads = [
        canonicalize_quad_clockwise_tl(q)
        for q in quads_norm
        if np.all(q >= -0.005) and np.all(q <= 1.005)
    ]
    if not valid_quads:
        return dense, reg_w, np.array([0.0, 0.0], dtype=np.float32)

    yy, xx = np.mgrid[0:grid, 0:grid].astype(np.float32)
    cell_x = (xx + 0.5) / grid
    cell_y = (yy + 0.5) / grid

    for q in valid_quads:
        q_clamped = np.clip(q, 0.0, 1.0)
        q_grid = q_clamped * (grid - 1)
        shrunk_grid = shrink_polygon_toward_centroid(q_grid, ratio=0.60)

        full_m = np.zeros((grid, grid), dtype=np.uint8)
        shrunk_m = np.zeros((grid, grid), dtype=np.uint8)
        cv2.fillConvexPoly(full_m, np.round(q_grid).astype(np.int32), 1)
        cv2.fillConvexPoly(shrunk_m, np.round(shrunk_grid).astype(np.int32), 1)
        cx_n, cy_n = float(q_clamped[:, 0].mean()), float(q_clamped[:, 1].mean())
        ix = min(grid - 1, max(0, int(cx_n * grid)))
        iy = min(grid - 1, max(0, int(cy_n * grid)))
        shrunk_m[iy, ix] = 1
        full_m[iy, ix] = 1

        dense[1] = np.maximum(dense[1], shrunk_m.astype(np.float32))
        dense[2] = np.maximum(dense[2], full_m.astype(np.float32))

        diag_g = float(np.linalg.norm(q_grid[2] - q_grid[0]))
        sigma = max(1.25, min(3.0, diag_g * 0.10))
        gx = cx_n * grid - 0.5
        gy = cy_n * grid - 0.5
        gauss = np.exp(-0.5 * (((xx - gx) ** 2 + (yy - gy) ** 2) / (sigma**2))).astype(np.float32)
        gauss[iy, ix] = 1.0
        dense[0] = np.maximum(dense[0], gauss)

        xmin, ymin = float(q_clamped[:, 0].min()), float(q_clamped[:, 1].min())
        xmax, ymax = float(q_clamped[:, 0].max()), float(q_clamped[:, 1].max())
        active = shrunk_m > 0
        reg_w[0, active] = 1.0
        dense[3, active] = xmin - cell_x[active]
        dense[4, active] = ymin - cell_y[active]
        dense[5, active] = xmax - cell_x[active]
        dense[6, active] = ymax - cell_y[active]

    has_doc = 1.0
    is_multi = 1.0 if len(valid_quads) >= 2 else 0.0
    return dense, reg_w, np.array([has_doc, is_multi], dtype=np.float32)


def build_stage2_targets(
    quad_roi_norm: np.ndarray | None,
    is_valid_complete: bool,
    all_four_visible: bool,
    clarity: float,
    grid: int = 64,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Build Stage-2 targets at 64x64:
    - hmap_target    [6, 64, 64] (TL, TR, BR, BL, any_corner, outer_edge)
    - off_target     [2, 64, 64] (shared subpixel dx, dy in [-0.5, 0.5])
    - off_mask       [1, 64, 64]
    - quality_target [3]
    """
    hmap = np.zeros((6, grid, grid), dtype=np.float32)
    off = np.zeros((2, grid, grid), dtype=np.float32)
    off_mask = np.zeros((1, grid, grid), dtype=np.float32)
    qual = np.array(
        [
            1.0 if is_valid_complete else 0.0,
            1.0 if all_four_visible else 0.0,
            float(np.clip(clarity, 0.0, 1.0)) if is_valid_complete else 0.0,
        ],
        dtype=np.float32,
    )
    if quad_roi_norm is None:
        return hmap, off, off_mask, qual

    q = canonicalize_quad_clockwise_tl(quad_roi_norm)
    yy, xx = np.mgrid[0:grid, 0:grid].astype(np.float32)

    sigma = 1.8
    for c_idx in range(4):
        u, v = float(q[c_idx, 0]), float(q[c_idx, 1])
        if -0.01 <= u <= 1.01 and -0.01 <= v <= 1.01:
            u_c = max(0.0, min(0.9999, u))
            v_c = max(0.0, min(0.9999, v))
            gx = u_c * grid - 0.5
            gy = v_c * grid - 0.5
            g = np.exp(-0.5 * (((xx - gx) ** 2 + (yy - gy) ** 2) / (sigma**2))).astype(np.float32)
            ix = min(grid - 1, max(0, int(u_c * grid)))
            iy = min(grid - 1, max(0, int(v_c * grid)))
            g[iy, ix] = 1.0
            hmap[c_idx] = g
            hmap[4] = np.maximum(hmap[4], g)

            for dy_i in (-1, 0, 1):
                for dx_i in (-1, 0, 1):
                    nx, ny = ix + dx_i, iy + dy_i
                    if 0 <= nx < grid and 0 <= ny < grid:
                        dx_sub = u_c * grid - (nx + 0.5)
                        dy_sub = v_c * grid - (ny + 0.5)
                        if abs(dx_sub) <= 0.5 and abs(dy_sub) <= 0.5:
                            off[0, ny, nx] = dx_sub
                            off[1, ny, nx] = dy_sub
                            off_mask[0, ny, nx] = 1.0
                        elif dx_i == 0 and dy_i == 0:
                            off[0, ny, nx] = max(-0.5, min(0.5, dx_sub))
                            off[1, ny, nx] = max(-0.5, min(0.5, dy_sub))
                            off_mask[0, ny, nx] = 1.0

    edge_canvas = np.zeros((grid, grid), dtype=np.float32)
    pts_g = q * (grid - 1)
    for c_idx in range(4):
        p1 = pts_g[c_idx]
        p2 = pts_g[(c_idx + 1) % 4]
        cv2.line(
            edge_canvas,
            (int(round(float(p1[0]))), int(round(float(p1[1])))),
            (int(round(float(p2[0]))), int(round(float(p2[1])))),
            1.0,
            2,
            lineType=cv2.LINE_AA,
        )
    edge_canvas = cv2.GaussianBlur(edge_canvas, (3, 3), 0.75)
    if edge_canvas.max() > 0:
        edge_canvas = np.clip(edge_canvas / max(float(edge_canvas.max()), 1e-6), 0.0, 1.0)
    hmap[5] = edge_canvas
    return hmap, off, off_mask, qual


def generate_stage1_sample(
    seed: int,
    bg_pool: list[SourceAsset],
    specimen_pool: list[SourceAsset] | None = None,
    out_size: int = 160,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Generate one Stage-1 training/validation sample deterministically from `seed`."""
    rng = np.random.default_rng(seed)
    # Render at camera-like aspect ratio, then resize to 160x160 so model learns aspect invariance
    aspect_scene = float(rng.choice([0.75, 4.0 / 3.0, 9.0 / 16.0, 16.0 / 9.0, 1.0]))
    if aspect_scene >= 1.0:
        sw, sh = 420, max(240, int(round(420 / aspect_scene)))
    else:
        sh, sw = 420, max(240, int(round(420 * aspect_scene)))

    bg = render_procedural_background(rng, sw, sh, bg_pool)
    bg_luma = float(bg.mean())

    roll = float(rng.random())
    quads_norm: list[np.ndarray] = []

    if roll < 0.16:
        # Pure negative scene (desk, real photo, shadow strip, or full-bleed scan)
        if rng.random() < 0.25:
            # Full-bleed digital white form (should NOT be detected as a crop-worthy card!)
            spec = CATALOG_SPECS[4]
            tex, _ = render_specimen_card_texture(rng, spec[0], spec[1], False, 128.0, specimen_pool)
            scene = cv2.resize(tex, (sw, sh), interpolation=cv2.INTER_LINEAR)
        else:
            scene = bg
        scene = apply_photometric_degradations(scene, rng, "random")
    elif roll < 0.24:
        # Truncated document (1-2 corners outside frame -> Stage-1 center/valid suppressed!)
        idx = int(rng.integers(0, len(CATALOG_SPECS)))
        kname, kasp, kround = CATALOG_SPECS[idx]
        tex, alpha = render_specimen_card_texture(rng, kname, kasp, kround, bg_luma, specimen_pool)
        q_px = sample_quad_homography(rng, kasp, sw, sh, (0.28, 0.72), max_persp=0.20, force_truncated=True)
        scene = warp_card_onto_scene(bg, tex, alpha, q_px, rng) if q_px is not None else bg
        scene = apply_photometric_degradations(scene, rng, "random")
        # Truncated quad is NOT added to valid_quads so Stage 1 does not propose a clipped crop!
    elif roll < 0.68:
        # Single complete document (spanning small ID card up to large 85% sheet)
        idx = int(rng.integers(0, len(CATALOG_SPECS)))
        kname, kasp, kround = CATALOG_SPECS[idx]
        area_rng = (0.08, 0.36) if rng.random() < 0.52 else (0.36, 0.84)
        q_px = sample_quad_homography(rng, kasp, sw, sh, area_rng, max_persp=0.25)
        scene = bg
        if q_px is not None:
            tex, alpha = render_specimen_card_texture(rng, kname, kasp, kround, bg_luma, specimen_pool)
            scene = warp_card_onto_scene(scene, tex, alpha, q_px, rng)
            quads_norm.append(q_px / np.array([sw - 1, sh - 1], dtype=np.float32))
        scene = apply_photometric_degradations(scene, rng, "random")
    else:
        # Multi-document scene (2 to 4 separate cards, including closely spaced pairs!)
        n_target = int(rng.choice([2, 2, 3, 4]))
        placed_px: list[np.ndarray] = []
        scene = bg
        for _ in range(n_target * 8):
            if len(placed_px) >= n_target:
                break
            idx = int(rng.integers(0, len(CATALOG_SPECS)))
            kname, kasp, kround = CATALOG_SPECS[idx]
            q_px = sample_quad_homography(
                rng,
                kasp,
                sw,
                sh,
                (0.06, 0.24 if n_target >= 3 else 0.32),
                max_persp=0.18,
            )
            if q_px is None:
                continue
            # Ensure non-overlapping with small minimum gap (~1.5% of image side)
            exp_q = shrink_polygon_toward_centroid(q_px, ratio=1.08)
            if any(polygon_iou(exp_q, shrink_polygon_toward_centroid(p, 1.08)) > 0.0 for p in placed_px):
                continue
            tex, alpha = render_specimen_card_texture(rng, kname, kasp, kround, bg_luma, specimen_pool)
            scene = warp_card_onto_scene(scene, tex, alpha, q_px, rng)
            placed_px.append(q_px)
            quads_norm.append(q_px / np.array([sw - 1, sh - 1], dtype=np.float32))
        scene = apply_photometric_degradations(scene, rng, "random")

    inp = cv2.resize(scene, (out_size, out_size), interpolation=cv2.INTER_LINEAR)
    inp_f = np.transpose(inp.astype(np.float32) / 255.0, (2, 0, 1))
    dense, reg_w, scene_t = build_stage1_targets(quads_norm, grid=40)
    return inp_f, dense, reg_w, scene_t


def generate_stage2_sample(
    seed: int,
    bg_pool: list[SourceAsset],
    specimen_pool: list[SourceAsset] | None = None,
    out_size: int = 128,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Generate one Stage-2 ROI training/validation sample deterministically."""
    rng = np.random.default_rng(seed)
    sw = int(rng.choice([360, 420, 480]))
    sh = int(rng.choice([360, 420, 480]))
    bg = render_procedural_background(rng, sw, sh, bg_pool)
    bg_luma = float(bg.mean())

    roll = float(rng.random())
    clarity = 1.0
    deg_mode = "random"
    if rng.random() < 0.16:
        deg_mode = "glare"
        clarity = 0.72
    elif rng.random() < 0.16:
        deg_mode = "blur"
        clarity = 0.68
    elif rng.random() < 0.16:
        deg_mode = "low_light"
        clarity = 0.75

    if roll < 0.16:
        # Pure negative ROI (background, shadow strip, cable, or full-bleed internal page)
        if rng.random() < 0.30:
            spec = CATALOG_SPECS[int(rng.integers(0, len(CATALOG_SPECS)))]
            tex, _ = render_specimen_card_texture(rng, spec[0], spec[1], False, 128.0, specimen_pool)
            roi_img = cv2.resize(tex, (out_size, out_size), interpolation=cv2.INTER_LINEAR)
        else:
            roi_img = cv2.resize(bg, (out_size, out_size), interpolation=cv2.INTER_LINEAR)
        roi_img = apply_photometric_degradations(roi_img, rng, deg_mode)
        hmap, off, off_m, qual = build_stage2_targets(None, False, False, 0.0, grid=64)
    elif roll < 0.30:
        # Truncated card in ROI (1-2 corners outside ROI -> valid=0, visible=0!)
        idx = int(rng.integers(0, len(CATALOG_SPECS)))
        kname, kasp, kround = CATALOG_SPECS[idx]
        q_px = sample_quad_homography(rng, kasp, sw, sh, (0.35, 0.78), max_persp=0.22, force_truncated=True)
        if q_px is None:
            roi_img = cv2.resize(bg, (out_size, out_size), interpolation=cv2.INTER_LINEAR)
            hmap, off, off_m, qual = build_stage2_targets(None, False, False, 0.0, grid=64)
        else:
            tex, alpha = render_specimen_card_texture(rng, kname, kasp, kround, bg_luma, specimen_pool)
            scene = warp_card_onto_scene(bg, tex, alpha, q_px, rng)
            scene = apply_photometric_degradations(scene, rng, deg_mode)
            roi_img = cv2.resize(scene, (out_size, out_size), interpolation=cv2.INTER_LINEAR)
            q_norm = q_px / np.array([sw - 1, sh - 1], dtype=np.float32)
            all_in = bool(np.all(q_norm >= 0.002) and np.all(q_norm <= 0.998))
            hmap, off, off_m, qual = build_stage2_targets(
                q_norm, is_valid_complete=all_in, all_four_visible=all_in, clarity=clarity, grid=64
            )
    else:
        # Valid complete card in ROI
        idx = int(rng.integers(0, len(CATALOG_SPECS)))
        kname, kasp, kround = CATALOG_SPECS[idx]
        q_px = sample_quad_homography(rng, kasp, sw, sh, (0.14, 0.78), max_persp=0.26)
        if q_px is None:
            roi_img = cv2.resize(bg, (out_size, out_size), interpolation=cv2.INTER_LINEAR)
            hmap, off, off_m, qual = build_stage2_targets(None, False, False, 0.0, grid=64)
        else:
            tex, alpha = render_specimen_card_texture(rng, kname, kasp, kround, bg_luma, specimen_pool)
            scene = warp_card_onto_scene(bg, tex, alpha, q_px, rng)

            if rng.random() < 0.30:
                idx2 = int(rng.integers(0, len(CATALOG_SPECS)))
                kn2, ka2, kr2 = CATALOG_SPECS[idx2]
                for _ in range(6):
                    q2 = sample_quad_homography(rng, ka2, sw, sh, (0.12, 0.35), max_persp=0.18, allow_truncation=True)
                    if q2 is not None and polygon_iou(
                        shrink_polygon_toward_centroid(q_px, 1.06),
                        shrink_polygon_toward_centroid(q2, 1.06),
                    ) == 0.0:
                        t2, a2 = render_specimen_card_texture(rng, kn2, ka2, kr2, bg_luma, specimen_pool)
                        scene = warp_card_onto_scene(scene, t2, a2, q2, rng)
                        break

            scene = apply_photometric_degradations(scene, rng, deg_mode)

            # Either crop around the card with realistic Stage-1 proposal jitter (75%) or use full frame (25%)
            if rng.random() < 0.78:
                xmin, ymin = q_px.min(axis=0)
                xmax, ymax = q_px.max(axis=0)
                bw_c, bh_c = xmax - xmin, ymax - ymin
                pad_l = bw_c * float(rng.uniform(0.06, 0.28))
                pad_r = bw_c * float(rng.uniform(0.06, 0.28))
                pad_t = bh_c * float(rng.uniform(0.06, 0.28))
                pad_b = bh_c * float(rng.uniform(0.06, 0.28))
                rx0 = max(0, int(math.floor(xmin - pad_l)))
                ry0 = max(0, int(math.floor(ymin - pad_t)))
                rx1 = min(sw - 1, int(math.ceil(xmax + pad_r)))
                ry1 = min(sh - 1, int(math.ceil(ymax + pad_b)))
                if rx1 - rx0 < 32 or ry1 - ry0 < 32:
                    rx0, ry0, rx1, ry1 = 0, 0, sw - 1, sh - 1
            else:
                rx0, ry0, rx1, ry1 = 0, 0, sw - 1, sh - 1

            crop = scene[ry0 : ry1 + 1, rx0 : rx1 + 1]
            roi_img = cv2.resize(crop, (out_size, out_size), interpolation=cv2.INTER_LINEAR)
            q_roi = (q_px - np.array([rx0, ry0], dtype=np.float32)) / np.array(
                [max(1, rx1 - rx0), max(1, ry1 - ry0)], dtype=np.float32
            )
            all_in = bool(np.all(q_roi >= 0.005) and np.all(q_roi <= 0.995))
            hmap, off, off_m, qual = build_stage2_targets(
                q_roi, is_valid_complete=all_in, all_four_visible=all_in, clarity=clarity, grid=64
            )

    inp_f = np.transpose(roi_img.astype(np.float32) / 255.0, (2, 0, 1))
    return inp_f, hmap, off, off_m, qual
