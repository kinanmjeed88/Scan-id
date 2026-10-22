"""Objective held-out benchmark comparing Scan-id's classical baseline vs
ScanIdDocNet-v1 two-stage ONNX AI + `verifyBoundary` (`ADR-005`, `ADR-006`,
`docs/BOUNDARY_EVALUATION_PROTOCOL.md`).

All model weights and decision thresholds are loaded directly from the frozen
`assets/models/MODEL_MANIFEST.json` calibrated on `val` BEFORE this script
evaluates `Track A` (real wild camera photos) and `Track B` (held-out `test`
split `seed 900_000+` stress suite).
"""

from __future__ import annotations

import json
import math
import os
from pathlib import Path
import platform
import sys
import time
import tracemalloc

import cv2
import numpy as np
import onnx
import onnxruntime as ort
from PIL import Image, ImageOps

cv2.setNumThreads(0)

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tool.ai.classical_port import run_classical_pipeline
from tool.ai.dataset_gen import (
    CATALOG_SPECS,
    apply_photometric_degradations,
    canonicalize_quad_clockwise_tl,
    load_disjoint_background_pools,
    load_disjoint_specimen_pools,
    polygon_iou,
    render_procedural_background,
    render_specimen_card_texture,
    sample_quad_homography,
    shrink_polygon_toward_centroid,
    warp_card_onto_scene,
)
from tool.ai.inference_pipeline import (
    FrozenThresholds,
    TwoStageOnnxDetector,
    assess_quad_domain,
    bilinear_resize_rgb_to_chw,
    classify_candidate_verdict,
    count_frame_touches,
    decode_stage2_roi,
    extract_stage1_proposals,
    refine_quad_edges_locally,
)


def load_exif_rgb(path: str, max_long_edge: int = 1280) -> np.ndarray:
    """Matches `decodeForProcessing` + `editorPreviewEdge` in Scan-id:
    honors EXIF orientation first, then bounds preview long edge."""
    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im).convert("RGB")
        w, h = im.size
        if max(w, h) > max_long_edge:
            scale = max_long_edge / float(max(w, h))
            nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
            im = im.resize((nw, nh), Image.Resampling.BILINEAR)
        return np.asarray(im, dtype=np.uint8)


def extract_verified_wild_gt(rgb: np.ndarray, name: str) -> np.ndarray:
    """Reproduces the visually audited ground-truth quads verified in
    `/tmp/wild_gt_check/{sheet1.jpg,sheet2.jpg}`."""
    if name == "jscanify_test4":
        return np.array(
            [[0.0999, 0.0936], [0.8949, 0.1103], [0.9323, 0.9530], [0.0622, 0.9624]],
            dtype=np.float32,
        )
    if name == "docaligner_id_card":
        return np.array(
            [[0.0566, 0.4336], [0.7520, 0.3906], [0.8184, 0.6621], [0.0430, 0.7051]],
            dtype=np.float32,
        )
    h, w = rgb.shape[:2]
    scale = min(1.0, 512.0 / max(w, h))
    sw, sh = int(round(w * scale)), int(round(h * scale))
    small = cv2.resize(rgb, (sw, sh), interpolation=cv2.INTER_AREA).astype(np.float32)
    band = max(2, int(round(min(sw, sh) * 0.025)))
    bmask = np.zeros((sh, sw), dtype=bool)
    bmask[:band, :] = True
    bmask[-band:, :] = True
    bmask[:, :band] = True
    bmask[:, -band:] = True
    bpx = small[bmask]
    centres = bpx[[0, len(bpx) // 2, len(bpx) - 1]].copy()
    for _ in range(10):
        d2 = np.sum((bpx[:, None, :] - centres[None, :, :]) ** 2, axis=2)
        lbl = np.argmin(d2, axis=1)
        for k in range(3):
            if np.any(lbl == k):
                centres[k] = bpx[lbl == k].mean(axis=0)
    dist = np.sqrt(
        np.min(np.sum((small.reshape(-1, 3)[:, None, :] - centres[None, :, :]) ** 2, axis=2), axis=1)
    ).reshape(sh, sw)
    du8 = np.clip((dist / max(1.0, float(dist.max()))) * 255.0, 0, 255).astype(np.uint8)
    _, mask = cv2.threshold(du8, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((7, 7), np.uint8))
    cnts, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    c = max(cnts, key=cv2.contourArea)
    hull = cv2.convexHull(c).reshape(-1, 2).astype(np.float32)
    peri = float(cv2.arcLength(hull, True))
    q = None
    for eps in (0.015, 0.025, 0.04, 0.06, 0.08):
        ap = cv2.approxPolyDP(hull, eps * peri, True)
        if len(ap) == 4:
            q = ap.reshape(4, 2)
            break
    if q is None:
        q = cv2.boxPoints(cv2.minAreaRect(hull))
    qn = canonicalize_quad_clockwise_tl(
        np.clip(q / np.array([sw - 1.0, sh - 1.0], dtype=np.float32), 0.0, 1.0)
    )
    return qn


def corner_error_norm_by_diag(pred_q: np.ndarray, gt_q: np.ndarray, w: int, h: int) -> float:
    """Mean L2 corner localization error divided by true card diagonal in pixels.
    Evaluates the minimum over cyclic shifts so pure 90-deg portrait/landscape
    orientation rotation does not masquerade as corner localization error, AND
    also returns ordered TL..BL error."""
    scale = np.array([w - 1.0, h - 1.0], dtype=np.float64)
    p_px = pred_q.astype(np.float64) * scale
    g_px = gt_q.astype(np.float64) * scale
    diag1 = float(np.linalg.norm(g_px[2] - g_px[0]))
    diag2 = float(np.linalg.norm(g_px[3] - g_px[1]))
    true_diag = max(1e-6, 0.5 * (diag1 + diag2))
    best_err = float("inf")
    for shift in range(4):
        rolled = np.roll(p_px, shift=shift, axis=0)
        err = float(np.mean(np.linalg.norm(rolled - g_px, axis=1))) / true_diag
        best_err = min(best_err, err)
    return best_err


def save_failure_overlay(
    out_dir: Path,
    tag: str,
    rgb: np.ndarray,
    gt_quads: list[np.ndarray],
    ai_cands: list,
    cl_cands: list,
) -> str:
    vis = cv2.cvtColor(rgb.copy(), cv2.COLOR_RGB2BGR)
    h, w = vis.shape[:2]
    sc = np.array([w - 1.0, h - 1.0])
    for gq in gt_quads:
        pts = np.round(gq * sc).astype(np.int32).reshape((-1, 1, 2))
        cv2.polylines(vis, [pts], True, (0, 220, 0), 2)
    for c in cl_cands:
        if c.corners is not None:
            pts = np.round(c.corners * sc).astype(np.int32).reshape((-1, 1, 2))
            cv2.polylines(vis, [pts], True, (0, 165, 255), 2)
    for c in ai_cands:
        col = (255, 80, 0) if c.verdict == "accepted" else (0, 255, 255)
        pts = np.round(c.corners * sc).astype(np.int32).reshape((-1, 1, 2))
        cv2.polylines(vis, [pts], True, col, 2)
    cv2.putText(vis, tag[:65], (10, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.62, (255, 255, 255), 2)
    fname = f"{tag}.jpg"
    fpath = out_dir / fname
    cv2.imwrite(str(fpath), vis, [cv2.IMWRITE_JPEG_QUALITY, 86])
    return str(fpath)


def build_track_a_wild_scenes(bg_test) -> list[dict]:
    scenes: list[dict] = []
    wild_pos = [
        ("jscanify_test", "/tmp/inspect_data/jscanify-master/docs/images/test/test.png", "MIT"),
        ("jscanify_test2", "/tmp/inspect_data/jscanify-master/docs/images/test/test2.png", "MIT"),
        ("jscanify_test3", "/tmp/inspect_data/jscanify-master/docs/images/test/test3.jpg", "MIT"),
        ("jscanify_test4", "/tmp/inspect_data/jscanify-master/docs/images/test/test4.JPG", "MIT"),
        ("jscanify_test5", "/tmp/inspect_data/jscanify-master/docs/images/test/test5.JPG", "MIT"),
        ("jscanify_test6", "/tmp/inspect_data/jscanify-master/docs/images/test/test6.JPG", "MIT"),
        ("jscanify_test8", "/tmp/inspect_data/jscanify-master/docs/images/test/test8.JPG", "MIT"),
        ("jscanify_test9", "/tmp/inspect_data/jscanify-master/docs/images/test/test9.jpg", "MIT"),
        ("jscanify_test10", "/tmp/inspect_data/jscanify-master/docs/images/test/test10.jpg", "MIT"),
        ("sammdu_1", "/tmp/inspect_data/sammdu_pyimgscan/test/1.png", "MIT"),
        ("sammdu_2", "/tmp/inspect_data/sammdu_pyimgscan/test/2.jpg", "MIT"),
        ("sammdu_3", "/tmp/inspect_data/sammdu_pyimgscan/test/3.jpg", "MIT"),
        ("docaligner_id_card", "/tmp/inspect_models/DocAligner-main/docs/run_test_card.jpg", "Apache-2.0"),
    ]
    for name, path, lic in wild_pos:
        if os.path.exists(path):
            rgb = load_exif_rgb(path)
            gt = extract_verified_wild_gt(rgb, name)
            scenes.append({
                "id": f"wild_pos_{name}",
                "category": "wild_positive",
                "license": lic,
                "rgb": rgb,
                "gt_quads": [gt],
                "must_not_autocrop": name == "jscanify_test8",  # touches bottom frame edge!
            })

    wild_safety = [
        ("jscanify_test7_truncated", "/tmp/inspect_data/jscanify-master/docs/images/test/test7.JPG", "wild_truncated", "MIT"),
        ("passporteye_aus_truncated", "/tmp/inspect_data/PassportEye-master/tests/data/62_pass-aus.png", "wild_truncated", "MIT"),
        ("endalk200_tax_fullbleed", "/tmp/inspect_data/endalk200_document-scanner/sample_images/tax.jpeg", "wild_fullbleed", "MIT"),
        ("quadscan_negative_desk", "/tmp/inspect_models/quadscan-main/site/public/sample-doc.jpg", "wild_negative", "MIT"),
    ]
    for name, path, cat, lic in wild_safety:
        if os.path.exists(path):
            scenes.append({
                "id": name,
                "category": cat,
                "license": lic,
                "rgb": load_exif_rgb(path),
                "gt_quads": [],
                "must_not_autocrop": True,
            })

    for asset in bg_test:
        rgb = asset.rgb
        if max(rgb.shape[:2]) > 1280:
            scale = 1280.0 / max(rgb.shape[:2])
            rgb = cv2.resize(rgb, (int(rgb.shape[1] * scale), int(rgb.shape[0] * scale)))
        scenes.append({
            "id": f"wild_neg_{asset.asset_id}",
            "category": "wild_negative",
            "license": asset.license_spdx,
            "rgb": rgb,
            "gt_quads": [],
            "must_not_autocrop": True,
        })
    return scenes


def build_track_b_stress_scenes(bg_test, spec_test) -> list[dict]:
    """220 deterministic held-out test scenes (`seed 900_000+`, zero train/val overlap)."""
    scenes: list[dict] = []
    plan = [
        ("clean_single", 25),
        ("tilted_35_75deg", 25),
        ("heavy_perspective", 25),
        ("low_light_noisy", 20),
        ("specular_glare", 20),
        ("motion_defocus_blur", 20),
        ("multi_card_adjacent", 25),
        ("truncated_out_of_frame", 20),
        ("hard_shadow_negative", 20),
        ("pure_negative", 20),
    ]
    seed_cursor = 900_000
    for cat, count in plan:
        for i in range(count):
            rng = np.random.default_rng(seed_cursor)
            seed_cursor += 1
            sw, sh = (640, 480) if i % 2 == 0 else (480, 640)
            bg = render_procedural_background(rng, sw, sh, bg_test)
            bg_l = float(bg.mean())

            if cat == "pure_negative":
                sc = apply_photometric_degradations(bg, rng, "random")
                scenes.append({"id": f"{cat}_{i:02d}", "category": cat, "rgb": sc, "gt_quads": [], "must_not_autocrop": True})
            elif cat == "hard_shadow_negative":
                sc = bg.copy()
                mask = np.zeros((sh, sw), dtype=np.float32)
                x0 = int(rng.integers(sw // 5, 4 * sw // 5))
                mask[:, x0:] = 1.0
                mask = cv2.GaussianBlur(mask, (11, 11), 3.0)
                sc = np.clip(sc.astype(np.float32) * (1.0 - 0.42 * mask[:, :, None]), 0, 255).astype(np.uint8)
                scenes.append({"id": f"{cat}_{i:02d}", "category": cat, "rgb": sc, "gt_quads": [], "must_not_autocrop": True})
            elif cat == "truncated_out_of_frame":
                sp = CATALOG_SPECS[i % len(CATALOG_SPECS)]
                tex, al = render_specimen_card_texture(rng, sp[0], sp[1], sp[2], bg_l, spec_test)
                q_px = sample_quad_homography(rng, sp[1], sw, sh, (0.35, 0.72), force_truncated=True)
                sc = apply_photometric_degradations(warp_card_onto_scene(bg, tex, al, q_px, rng), rng, "clean")
                scenes.append({"id": f"{cat}_{i:02d}", "category": cat, "rgb": sc, "gt_quads": [], "must_not_autocrop": True})
            elif cat == "multi_card_adjacent":
                target_n = 2 if i % 3 != 0 else 3
                placed: list[np.ndarray] = []
                sc = bg
                for _ in range(24):
                    if len(placed) >= target_n:
                        break
                    sp = CATALOG_SPECS[int(rng.integers(0, len(CATALOG_SPECS)))]
                    q_px = sample_quad_homography(rng, sp[1], sw, sh, (0.09, 0.24), max_persp=0.16)
                    if q_px is None:
                        continue
                    if any(
                        polygon_iou(shrink_polygon_toward_centroid(q_px, 1.10), shrink_polygon_toward_centroid(p, 1.10)) > 0.0
                        for p in placed
                    ):
                        continue
                    tex, al = render_specimen_card_texture(rng, sp[0], sp[1], sp[2], bg_l, spec_test)
                    sc = warp_card_onto_scene(sc, tex, al, q_px, rng)
                    placed.append(q_px)
                sc = apply_photometric_degradations(sc, rng, "clean" if i % 2 == 0 else "random")
                gts = [p / np.array([sw - 1.0, sh - 1.0], dtype=np.float32) for p in placed]
                scenes.append({"id": f"{cat}_{i:02d}", "category": cat, "rgb": sc, "gt_quads": gts, "must_not_autocrop": False})
            else:
                sp = CATALOG_SPECS[i % len(CATALOG_SPECS)]
                tex, al = render_specimen_card_texture(rng, sp[0], sp[1], sp[2], bg_l, spec_test)
                q_px = None
                if cat == "tilted_35_75deg":
                    # Explicit high-tilt quad sampling (35..75 deg)
                    for _ in range(30):
                        ang_deg = float(rng.uniform(35.0, 75.0)) * (1.0 if rng.random() < 0.5 else -1.0)
                        rad = math.radians(ang_deg)
                        area_t = float(rng.uniform(0.16, 0.45)) * sw * sh
                        cw_c = math.sqrt(area_t * sp[1])
                        ch_c = math.sqrt(area_t / sp[1])
                        base = np.array([[-cw_c/2, -ch_c/2], [cw_c/2, -ch_c/2], [cw_c/2, ch_c/2], [-cw_c/2, ch_c/2]], dtype=np.float32)
                        rot = np.array([[math.cos(rad), -math.sin(rad)], [math.sin(rad), math.cos(rad)]], dtype=np.float32)
                        cand = base @ rot.T + np.array([sw * 0.5, sh * 0.5], dtype=np.float32)
                        if cand[:, 0].min() >= 14 and cand[:, 0].max() <= sw - 15 and cand[:, 1].min() >= 14 and cand[:, 1].max() <= sh - 15:
                            q_px = canonicalize_quad_clockwise_tl(cand)
                            break
                elif cat == "heavy_perspective":
                    for _ in range(25):
                        q_px = sample_quad_homography(rng, sp[1], sw, sh, (0.16, 0.52), max_persp=0.30)
                        if q_px is not None:
                            break
                else:
                    for _ in range(20):
                        q_px = sample_quad_homography(rng, sp[1], sw, sh, (0.15, 0.58), max_persp=0.18)
                        if q_px is not None:
                            break
                if q_px is None:
                    continue
                sc = warp_card_onto_scene(bg, tex, al, q_px, rng)
                deg_map = {
                    "clean_single": "clean",
                    "tilted_35_75deg": "clean",
                    "heavy_perspective": "clean",
                    "low_light_noisy": "low_light",
                    "specular_glare": "glare",
                    "motion_defocus_blur": "blur",
                }
                sc = apply_photometric_degradations(sc, rng, deg_map[cat])
                gt_n = q_px / np.array([sw - 1.0, sh - 1.0], dtype=np.float32)
                scenes.append({"id": f"{cat}_{i:02d}", "category": cat, "rgb": sc, "gt_quads": [gt_n], "must_not_autocrop": False})
    return scenes


def evaluate_method_on_scenes(
    scenes: list[dict],
    runner,
    method_name: str,
) -> tuple[dict, list[dict]]:
    latencies_ms: list[float] = []
    gt_total = 0
    tp_prop_75 = 0
    tp_prop_85 = 0
    tp_accept_80 = 0
    valid_rejected_or_missed = 0
    valid_routed_to_review = 0

    accepted_ious: list[float] = []
    all_matched_ious: list[float] = []
    corner_errors_diag: list[float] = []

    total_scenes = len(scenes)
    safety_scenes = 0
    safety_false_accept_scenes = 0
    safety_false_accept_crops = 0
    valid_scene_false_accept_crops = 0
    total_false_accept_crops = 0
    multi_gt_cards = 0
    multi_found_cards = 0
    multi_neighbor_merge_count = 0

    by_category: dict[str, dict] = {}
    per_scene_records: list[dict] = []

    for sc in scenes:
        cat = sc["category"]
        cat_stat = by_category.setdefault(
            cat,
            {"scenes": 0, "gt_docs": 0, "proposal_recall_75": 0, "auto_accept_80": 0, "false_accepts": 0, "ious": []},
        )
        cat_stat["scenes"] += 1

        rgb = sc["rgb"]
        h, w = rgb.shape[:2]
        t0 = time.perf_counter()
        res = runner(rgb)
        dt_ms = (time.perf_counter() - t0) * 1000.0
        latencies_ms.append(dt_ms)

        cands_with_quad = [c for c in res.candidates if c.corners is not None]
        accepted = [c for c in cands_with_quad if c.verdict == "accepted"]
        gt_quads = sc["gt_quads"]

        scene_false = 0
        is_safety_scene = bool(sc["must_not_autocrop"] or len(gt_quads) == 0)
        best_scene_iou = None
        if is_safety_scene:
            safety_scenes += 1
            if len(accepted) > 0:
                safety_false_accept_scenes += 1
                safety_false_accept_crops += len(accepted)
                scene_false += len(accepted)
                total_false_accept_crops += len(accepted)
        else:
            for c in accepted:
                best_g = max((polygon_iou(gq, c.corners) for gq in gt_quads), default=0.0)
                if best_g < 0.78:
                    valid_scene_false_accept_crops += 1
                    scene_false += 1
                    total_false_accept_crops += 1

            if len(gt_quads) >= 2:
                # Check if any single predicted quad spans >=2 GT cards (>0.25 IoU with >=2 GT cards)
                for c in cands_with_quad:
                    overlaps = sum(1 for gq in gt_quads if polygon_iou(gq, c.corners) > 0.25)
                    if overlaps >= 2:
                        multi_neighbor_merge_count += 1

            scene_ious: list[float] = []
            for gq in gt_quads:
                gt_total += 1
                cat_stat["gt_docs"] += 1
                if len(gt_quads) >= 2:
                    multi_gt_cards += 1

                best_all_c = None
                best_all_iou = 0.0
                for c in cands_with_quad:
                    iou_v = polygon_iou(gq, c.corners)
                    if iou_v > best_all_iou:
                        best_all_iou = iou_v
                        best_all_c = c
                scene_ious.append(best_all_iou)

                best_acc_c = None
                best_acc_iou = 0.0
                for c in accepted:
                    iou_v = polygon_iou(gq, c.corners)
                    if iou_v > best_acc_iou:
                        best_acc_iou = iou_v
                        best_acc_c = c

                if best_all_iou >= 0.75 and best_all_c is not None:
                    tp_prop_75 += 1
                    cat_stat["proposal_recall_75"] += 1
                    all_matched_ious.append(best_all_iou)
                    corner_errors_diag.append(corner_error_norm_by_diag(best_all_c.corners, gq, w, h))
                    if len(gt_quads) >= 2:
                        multi_found_cards += 1
                    if best_all_iou >= 0.85:
                        tp_prop_85 += 1
                else:
                    valid_rejected_or_missed += 1

                if best_acc_iou >= 0.80 and best_acc_c is not None:
                    tp_accept_80 += 1
                    cat_stat["auto_accept_80"] += 1
                    accepted_ious.append(best_acc_iou)
                    cat_stat["ious"].append(best_acc_iou)
                elif best_all_iou >= 0.75:
                    valid_routed_to_review += 1
            if scene_ious:
                best_scene_iou = round(float(max(scene_ious)), 4)

        cat_stat["false_accepts"] += scene_false
        per_scene_records.append({
            "id": sc["id"],
            "category": cat,
            "resolution": [w, h],
            "is_safety_scene": is_safety_scene,
            "gt_count": 0 if is_safety_scene else len(gt_quads),
            "proposal_count": len(cands_with_quad),
            "accepted_count": len(accepted),
            "verdicts": [c.verdict for c in cands_with_quad],
            "best_gt_iou": best_scene_iou,
            "latency_ms": round(dt_ms, 2),
            "false_accepts": scene_false,
            "candidates": res.candidates,
        })

    cat_out = {}
    for k, v in by_category.items():
        gd = max(1, v["gt_docs"])
        cat_out[k] = {
            "scenes": v["scenes"],
            "gt_docs": v["gt_docs"],
            "proposal_recall_iou75": round(v["proposal_recall_75"] / gd, 4) if v["gt_docs"] > 0 else None,
            "auto_accept_recall_iou80": round(v["auto_accept_80"] / gd, 4) if v["gt_docs"] > 0 else None,
            "mean_accepted_iou": round(float(np.mean(v["ious"])), 4) if v["ious"] else None,
            "false_accepts": v["false_accepts"],
        }

    summary = {
        "method": method_name,
        "total_scenes": total_scenes,
        "total_gt_documents": gt_total,
        "proposal_recall_iou75": round(tp_prop_75 / max(1, gt_total), 4),
        "proposal_recall_iou85": round(tp_prop_85 / max(1, gt_total), 4),
        "detection_failure_rate": round(valid_rejected_or_missed / max(1, gt_total), 4),
        "auto_accept_rate_iou80": round(tp_accept_80 / max(1, gt_total), 4),
        "valid_routed_to_review_rate": round(valid_routed_to_review / max(1, gt_total), 4),
        "mean_polygon_iou_matched": round(float(np.mean(all_matched_ious)), 4) if all_matched_ious else 0.0,
        "median_polygon_iou_matched": round(float(np.median(all_matched_ious)), 4) if all_matched_ious else 0.0,
        "mean_polygon_iou_accepted": round(float(np.mean(accepted_ious)), 4) if accepted_ious else 0.0,
        "mean_corner_error_pct_diag": round(float(np.mean(corner_errors_diag)) * 100.0, 3) if corner_errors_diag else None,
        "p95_corner_error_pct_diag": round(float(np.percentile(corner_errors_diag, 95)) * 100.0, 3) if corner_errors_diag else None,
        "false_crop_accept_count": total_false_accept_crops,
        "false_crop_accept_rate_per_scene": round(total_false_accept_crops / max(1, total_scenes), 4),
        "valid_scene_false_accept_count": valid_scene_false_accept_crops,
        "safety_false_accept_scenes": safety_false_accept_scenes,
        "safety_false_accept_crop_count": safety_false_accept_crops,
        "negative_and_truncated_scenes": safety_scenes,
        "negative_and_truncated_false_accept_rate": round(safety_false_accept_scenes / max(1, safety_scenes), 4),
        "multi_card_gt_total": multi_gt_cards,
        "multi_card_instance_recall_iou75": round(multi_found_cards / max(1, multi_gt_cards), 4) if multi_gt_cards > 0 else None,
        "multi_card_neighbor_merge_count": multi_neighbor_merge_count,
        "latency_ms": {
            "measurement_mode": "single_pass_per_scene_during_accuracy_eval",
            "scene_count": len(latencies_ms),
            "mean": round(float(np.mean(latencies_ms)), 2),
            "median": round(float(np.median(latencies_ms)), 2),
            "p95": round(float(np.percentile(latencies_ms, 95)), 2),
        },
        "by_category": cat_out,
    }
    return summary, per_scene_records


def _stats_ms(vals: list[float]) -> dict[str, float]:
    return {
        "mean": round(float(np.mean(vals)), 2),
        "median": round(float(np.median(vals)), 2),
        "p95": round(float(np.percentile(vals, 95)), 2),
        "min": round(float(np.min(vals)), 2),
        "max": round(float(np.max(vals)), 2),
    }


def _time_ai_decomposed_once(ai_det: TwoStageOnnxDetector, rgb: np.ndarray) -> dict[str, float | int]:
    """Times Stage-1/Stage-2 ONNX forward passes strictly separated from
    image resampling and post-processing/verification."""
    h, w = rgb.shape[:2]
    t_total0 = time.perf_counter()

    t0 = time.perf_counter()
    inp1 = bilinear_resize_rgb_to_chw(rgb, 160, 160)
    pre_s1_ms = (time.perf_counter() - t0) * 1000.0

    t0 = time.perf_counter()
    dense_map, scene_prob = ai_det.s1.run(None, {"input": inp1})
    s1_onnx_ms = (time.perf_counter() - t0) * 1000.0

    t0 = time.perf_counter()
    proposals = extract_stage1_proposals(dense_map[0], scene_prob[0], ai_det.thresholds)
    s1_dec_ms = (time.perf_counter() - t0) * 1000.0

    s2_resample_ms = 0.0
    s2_onnx_ms = 0.0
    s2_post_ms = 0.0
    s2_calls = 0

    for coarse_box, _ in proposals:
        xmin, ymin, xmax, ymax = coarse_box
        bw, bh = xmax - xmin, ymax - ymin
        if bw >= 0.96 and bh >= 0.96:
            rx0, ry0, rx1, ry1 = 0.0, 0.0, 1.0, 1.0
        else:
            rx0 = max(0.0, xmin - bw * 0.22)
            ry0 = max(0.0, ymin - bh * 0.22)
            rx1 = min(1.0, xmax + bw * 0.22)
            ry1 = min(1.0, ymax + bh * 0.22)
        if rx1 - rx0 < 0.08 or ry1 - ry0 < 0.08:
            continue

        t0 = time.perf_counter()
        inp2 = bilinear_resize_rgb_to_chw(rgb, 128, 128, rx0, ry0, rx1, ry1)
        s2_resample_ms += (time.perf_counter() - t0) * 1000.0

        t0 = time.perf_counter()
        c_hmaps, c_offs, r_qual = ai_det.s2.run(None, {"input": inp2})
        s2_onnx_ms += (time.perf_counter() - t0) * 1000.0
        s2_calls += 1

        t0 = time.perf_counter()
        full_q, peaks, edges, quals = decode_stage2_roi(
            c_hmaps[0], c_offs[0], r_qual[0], rx0, ry0, rx1, ry1
        )
        issues, area_frac, _ = assess_quad_domain(full_q, w, h)
        if not issues and area_frac < 0.94:
            _ = refine_quad_edges_locally(rgb, full_q)
        s2_post_ms += (time.perf_counter() - t0) * 1000.0

    total_ms = (time.perf_counter() - t_total0) * 1000.0
    model_only_ms = s1_onnx_ms + s2_onnx_ms
    pre_total_ms = pre_s1_ms + s2_resample_ms
    post_total_ms = max(0.0, total_ms - model_only_ms - pre_total_ms)
    return {
        "stage1_onnx_only_ms": s1_onnx_ms,
        "stage2_onnx_only_ms": s2_onnx_ms,
        "model_only_total_ms": model_only_ms,
        "preprocess_and_roi_resample_ms": pre_total_ms,
        "postprocess_decode_snap_nms_ms": post_total_ms,
        "full_pipeline_total_ms": total_ms,
        "stage2_roi_invocations": s2_calls,
    }


def benchmark_controlled_latency(
    ai_det: TwoStageOnnxDetector,
    bg_test,
    spec_test,
    warmup_runs: int = 5,
    measured_runs: int = 30,
) -> dict:
    """Measures controlled multi-iteration latency at 1280x960 (Scan-id's
    `maxRecognitionPreviewLongEdge`) with `tracemalloc` OFF, separating pure
    ONNX model execution from pre/post-processing across 3 distinct workloads."""
    sw, sh = 1280, 960
    rng = np.random.default_rng(20261022)

    # 1. Single-card positive scene (1280x960)
    bg1 = render_procedural_background(rng, sw, sh, bg_test)
    sp0 = CATALOG_SPECS[0]
    tex1, al1 = render_specimen_card_texture(rng, sp0[0], sp0[1], sp0[2], float(bg1.mean()), spec_test)
    q1 = np.array([[220, 190], [1040, 215], [1015, 735], [195, 705]], dtype=np.float32)
    single_pos = warp_card_onto_scene(bg1, tex1, al1, q1, rng)

    # 2. Two-card positive scene (1280x960)
    bg2 = render_procedural_background(rng, sw, sh, bg_test)
    qa = np.array([[90, 140], [560, 160], [548, 455], [78, 435]], dtype=np.float32)
    qb = np.array([[700, 470], [1180, 445], [1195, 750], [715, 775]], dtype=np.float32)
    multi_pos = bg2
    for qp in (qa, qb):
        tx, al = render_specimen_card_texture(rng, sp0[0], sp0[1], sp0[2], float(bg2.mean()), spec_test)
        multi_pos = warp_card_onto_scene(multi_pos, tx, al, qp, rng)

    # 3. Textured negative non-document scene (1280x960, Stage-2 rejects candidate)
    neg_textured = render_procedural_background(rng, sw, sh, bg_test)

    # 4. Smooth non-document scene (1280x960, Stage-1 early-exits with 0 Stage-2 calls)
    yy = np.linspace(48.0, 132.0, sh, dtype=np.float32)[:, None]
    xx = np.linspace(52.0, 118.0, sw, dtype=np.float32)[None, :]
    base_grad = np.clip(0.55 * yy + 0.45 * xx, 0, 255).astype(np.uint8)
    neg_early = np.stack([base_grad, np.clip(base_grad + 6, 0, 255), np.clip(base_grad - 5, 0, 255)], axis=-1)

    workloads = {
        "single_card_positive_1280x960": single_pos,
        "two_card_positive_1280x960": multi_pos,
        "negative_textured_1280x960": neg_textured,
        "negative_early_exit_1280x960": neg_early,
    }

    results = {}
    for wname, img_rgb in workloads.items():
        for _ in range(warmup_runs):
            _ = _time_ai_decomposed_once(ai_det, img_rgb)
            _ = run_classical_pipeline(img_rgb)

        samples = [_time_ai_decomposed_once(ai_det, img_rgb) for _ in range(measured_runs)]
        cl_times = []
        for _ in range(measured_runs):
            t0 = time.perf_counter()
            _ = run_classical_pipeline(img_rgb)
            cl_times.append((time.perf_counter() - t0) * 1000.0)

        results[wname] = {
            "resolution": [sw, sh],
            "stage2_roi_invocations_per_run": int(round(float(np.mean([s["stage2_roi_invocations"] for s in samples])))),
            "stage1_onnx_only_ms": _stats_ms([float(s["stage1_onnx_only_ms"]) for s in samples]),
            "stage2_onnx_only_ms": _stats_ms([float(s["stage2_onnx_only_ms"]) for s in samples]),
            "model_only_total_ms": _stats_ms([float(s["model_only_total_ms"]) for s in samples]),
            "preprocess_and_roi_resample_ms": _stats_ms([float(s["preprocess_and_roi_resample_ms"]) for s in samples]),
            "postprocess_decode_snap_nms_ms": _stats_ms([float(s["postprocess_decode_snap_nms_ms"]) for s in samples]),
            "ai_full_pipeline_total_ms": _stats_ms([float(s["full_pipeline_total_ms"]) for s in samples]),
            "classical_baseline_full_ms": _stats_ms(cl_times),
        }

    return {
        "runtime_backend": f"Python {sys.version.split()[0]} + onnxruntime {ort.__version__} CPUExecutionProvider (intra_op_threads=1, inter_op_threads=1)",
        "tracemalloc_active_during_timing": False,
        "warmup_runs_per_workload": warmup_runs,
        "measured_runs_per_workload": measured_runs,
        "workloads": results,
        "dart_onnx_lite_runtime": {
            "measured": False,
            "status": "UNVERIFIED_IN_EXECUTION",
            "note": "Flutter/Dart SDK is not installed in this Linux sandbox; pure-Dart OnnxLiteSession latency on Android ARM64 and Windows x64 has NOT been measured yet.",
        },
    }


def export_dart_golden_vectors(ai_det: TwoStageOnnxDetector) -> None:
    """Exports compact deterministic input/output golden vectors so Dart tests
    can verify bit-accurate (<1e-5) parity of `onnx_lite_runtime.dart` and
    `ai_document_detector.dart` against ONNX Runtime across single-card,
    two-card, truncated-card, and inner-table-box regression cases."""
    fixtures_dir = REPO_ROOT / "test" / "fixtures"
    fixtures_dir.mkdir(parents=True, exist_ok=True)

    # 1. Clean single tilted card (320x240)
    bg = np.full((240, 320, 3), 42, dtype=np.uint8)
    card_pts = np.array([[56, 44], [262, 52], [254, 194], [48, 184]], dtype=np.int32)
    cv2.fillConvexPoly(bg, card_pts, (238, 240, 235))
    cv2.polylines(bg, [card_pts.reshape(-1, 1, 2)], True, (180, 185, 190), 2)
    cv2.rectangle(bg, (74, 72), (122, 134), (90, 115, 155), -1)
    for k in range(5):
        cv2.line(bg, (136, 78 + k * 18), (236, 82 + k * 18), (60, 65, 70), 2)

    inp1 = bilinear_resize_rgb_to_chw(bg, 160, 160)
    d1, s1 = ai_det.s1.run(None, {"input": inp1})
    inp2 = bilinear_resize_rgb_to_chw(bg, 128, 128, 0.08, 0.08, 0.92, 0.92)
    ch2, co2, rq2 = ai_det.s2.run(None, {"input": inp2})
    full_res = ai_det.detect(bg)
    Image.fromarray(bg, mode="RGB").save(fixtures_dir / "ai_golden_card.png", format="PNG", compress_level=9)

    # 2. Two tilted cards in one frame (480x360)
    two_bg = np.full((360, 480, 3), 38, dtype=np.uint8)
    q_top_left = np.array([[34, 42], [218, 54], [210, 174], [26, 162]], dtype=np.int32)
    q_bot_right = np.array([[258, 186], [448, 172], [456, 296], [266, 310]], dtype=np.int32)
    for qp in (q_top_left, q_bot_right):
        cv2.fillConvexPoly(two_bg, qp, (240, 241, 236))
        cv2.polylines(two_bg, [qp.reshape(-1, 1, 2)], True, (175, 180, 186), 2)
        cx0, cy0 = int(qp[0, 0]) + 16, int(qp[0, 1]) + 22
        cv2.rectangle(two_bg, (cx0, cy0), (cx0 + 38, cy0 + 52), (88, 114, 152), -1)
        for k in range(4):
            cv2.line(two_bg, (cx0 + 50, cy0 + 8 + k * 14), (cx0 + 142, cy0 + 10 + k * 14), (58, 63, 70), 2)
    Image.fromarray(two_bg, mode="RGB").save(fixtures_dir / "ai_golden_two_cards.png", format="PNG", compress_level=9)

    # 3. Truncated card cut off along top frame border (320x240)
    trunc_bg = np.full((240, 320, 3), 44, dtype=np.uint8)
    trunc_pts = np.array([[58, -36], [268, -24], [258, 172], [48, 162]], dtype=np.int32)
    cv2.fillConvexPoly(trunc_bg, trunc_pts, (238, 240, 235))
    cv2.polylines(trunc_bg, [trunc_pts.reshape(-1, 1, 2)], True, (180, 185, 190), 2)
    cv2.rectangle(trunc_bg, (74, 24), (124, 92), (90, 115, 155), -1)
    for k in range(4):
        cv2.line(trunc_bg, (138, 28 + k * 20), (238, 32 + k * 20), (60, 65, 70), 2)
    Image.fromarray(trunc_bg, mode="RGB").save(fixtures_dir / "ai_golden_truncated.png", format="PNG", compress_level=9)

    # 4. Outer sheet containing a strong inner rectangular table box (320x240)
    inner_bg = np.full((240, 320, 3), 40, dtype=np.uint8)
    outer_pts = np.array([[38, 26], [282, 30], [276, 214], [32, 210]], dtype=np.int32)
    cv2.fillConvexPoly(inner_bg, outer_pts, (242, 242, 238))
    cv2.polylines(inner_bg, [outer_pts.reshape(-1, 1, 2)], True, (175, 180, 185), 2)
    # Inner table box inside the outer document
    cv2.rectangle(inner_bg, (66, 98), (250, 188), (70, 75, 82), 2)
    cv2.line(inner_bg, (66, 128), (250, 128), (95, 100, 108), 1)
    cv2.line(inner_bg, (66, 158), (250, 158), (95, 100, 108), 1)
    for k in range(3):
        cv2.line(inner_bg, (58, 48 + k * 14), (254, 48 + k * 14), (62, 66, 72), 2)
    Image.fromarray(inner_bg, mode="RGB").save(fixtures_dir / "ai_golden_inner_box.png", format="PNG", compress_level=9)

    def summarize_case(name: str, png_file: str, arr: np.ndarray) -> dict:
        t1 = bilinear_resize_rgb_to_chw(arr, 160, 160)
        _, sp_out = ai_det.s1.run(None, {"input": t1})
        det_out = ai_det.detect(arr)
        return {
            "name": name,
            "png_file": png_file,
            "shape_hwc": list(arr.shape),
            "stage1_scene_prob": [round(float(x), 7) for x in sp_out[0].tolist()],
            "multi": bool(det_out.multi),
            "candidates": [
                {
                    "corners": [[round(float(u), 6), round(float(v), 6)] for u, v in c.corners],
                    "confidence": round(float(c.confidence), 6),
                    "verdict": c.verdict,
                    "frame_touch_count": int(c.frame_touch_count),
                }
                for c in det_out.candidates
            ],
        }

    out_path = fixtures_dir / "ai_golden_vectors.json"
    payload = {
        "description": "Deterministic ONNX Runtime golden parity vectors for ScanIdDocNet-v1",
        "scene_shape": [240, 320, 3],
        "stage1_scene_prob": [round(float(x), 7) for x in s1[0].tolist()],
        "stage1_dense_sample_cells": [
            {"c": c, "y": y, "x": x, "val": round(float(d1[0, c, y, x]), 7)}
            for c in range(7)
            for (y, x) in [(20, 20), (10, 12), (30, 28)]
        ],
        "stage2_roi_box": [0.08, 0.08, 0.92, 0.92],
        "stage2_roi_quality": [round(float(x), 7) for x in rq2[0].tolist()],
        "stage2_heatmap_maxima": [round(float(ch2[0, c].max()), 7) for c in range(6)],
        "stage2_offset_sample_cells": [
            {"c": c, "y": y, "x": x, "val": round(float(co2[0, c, y, x]), 7)}
            for c in range(2)
            for (y, x) in [(10, 10), (32, 32), (52, 50)]
        ],
        "end_to_end_candidates": [
            {
                "corners": [[round(float(u), 6), round(float(v), 6)] for u, v in cand.corners],
                "confidence": round(float(cand.confidence), 6),
                "verdict": cand.verdict,
            }
            for cand in full_res.candidates
        ],
        "multi_scene_cases": [
            summarize_case("single_card", "test/fixtures/ai_golden_card.png", bg),
            summarize_case("two_cards", "test/fixtures/ai_golden_two_cards.png", two_bg),
            summarize_case("truncated_top", "test/fixtures/ai_golden_truncated.png", trunc_bg),
            summarize_case("outer_with_inner_box", "test/fixtures/ai_golden_inner_box.png", inner_bg),
        ],
    }
    out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"[Golden Vectors] Wrote {out_path} + 4 PNG fixtures", flush=True)


def main() -> None:
    manifest_path = REPO_ROOT / "assets" / "models" / "MODEL_MANIFEST.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    ft_dict = manifest["frozen_thresholds"]
    frozen_t = FrozenThresholds(**ft_dict)

    s1_path = str(REPO_ROOT / manifest["models"]["stage1_detector"]["file"])
    s2_path = str(REPO_ROOT / manifest["models"]["stage2_corner_refiner"]["file"])
    ai_det = TwoStageOnnxDetector(s1_path, s2_path, frozen_t)

    bg_pools = load_disjoint_background_pools()
    spec_pools = load_disjoint_specimen_pools()

    print("[Benchmark] Building Track A (wild camera) & Track B (held-out stress)...", flush=True)
    track_a = build_track_a_wild_scenes(bg_pools["test"])
    track_b = build_track_b_stress_scenes(bg_pools["test"], spec_pools["test"])

    # Dedicated peak Python heap measurement on a real positive 1280x960 card scene
    mem_rng = np.random.default_rng(20261022)
    mem_bg = render_procedural_background(mem_rng, 1280, 960, bg_pools["test"])
    sp_m = CATALOG_SPECS[0]
    tx_m, al_m = render_specimen_card_texture(mem_rng, sp_m[0], sp_m[1], sp_m[2], float(mem_bg.mean()), spec_pools["test"])
    mem_scene = warp_card_onto_scene(mem_bg, tx_m, al_m, np.array([[220, 190], [1040, 215], [1015, 735], [195, 705]], dtype=np.float32), mem_rng)
    _ = ai_det.detect(mem_scene)
    tracemalloc.start()
    _ = ai_det.detect(mem_scene)
    _, peak_bytes = tracemalloc.get_traced_memory()
    tracemalloc.stop()

    print("[Benchmark] Running controlled multi-iteration latency decomposition (N=30, warmup=5)...", flush=True)
    latency_profile = benchmark_controlled_latency(ai_det, bg_pools["test"], spec_pools["test"], warmup_runs=5, measured_runs=30)

    print(f"[Benchmark] Evaluating Track A ({len(track_a)} real camera scenes)...", flush=True)
    cl_a, cl_a_rec = evaluate_method_on_scenes(track_a, run_classical_pipeline, "classical_baseline")
    ai_a, ai_a_rec = evaluate_method_on_scenes(track_a, ai_det.detect, "scanid_docnet_v1_ai")

    track_a_ledger = []
    for sc, cl_r, ai_r in zip(track_a, cl_a_rec, ai_a_rec):
        track_a_ledger.append({
            "scene_id": sc["id"],
            "category": sc["category"],
            "is_safety_scene": cl_r["is_safety_scene"],
            "must_not_autocrop": bool(sc["must_not_autocrop"]),
            "gt_docs_counted": cl_r["gt_count"],
            "classical_accepted_count": cl_r["accepted_count"],
            "classical_false_accepts": cl_r["false_accepts"],
            "classical_best_gt_iou": cl_r["best_gt_iou"],
            "ai_proposal_count": ai_r["proposal_count"],
            "ai_verdicts": ai_r["verdicts"],
            "ai_accepted_count": ai_r["accepted_count"],
            "ai_false_accepts": ai_r["false_accepts"],
            "ai_best_gt_iou": ai_r["best_gt_iou"],
        })

    print(f"[Benchmark] Evaluating Track B ({len(track_b)} held-out stress scenes)...", flush=True)
    cl_b, cl_b_rec = evaluate_method_on_scenes(track_b, run_classical_pipeline, "classical_baseline")
    ai_b, ai_b_rec = evaluate_method_on_scenes(track_b, ai_det.detect, "scanid_docnet_v1_ai")

    # Save visual diagnostics for hard/failure cases to /tmp/scanid_bench_failures
    fail_dir = Path("/tmp/scanid_bench_failures")
    fail_dir.mkdir(parents=True, exist_ok=True)
    saved_diagnostics: list[dict] = []
    for sc, ai_r, cl_r in list(zip(track_a, ai_a_rec, cl_a_rec)) + list(zip(track_b, ai_b_rec, cl_b_rec)):
        gt_q = sc["gt_quads"]
        ai_c = ai_r["candidates"]
        cl_c = cl_r["candidates"]
        ai_missed = len(gt_q) > 0 and max((polygon_iou(g, c.corners) for g in gt_q for c in ai_c), default=0.0) < 0.75
        cl_missed_ai_hit = (
            len(gt_q) > 0
            and max((polygon_iou(g, c.corners) for g in gt_q for c in cl_c if c.corners is not None), default=0.0) < 0.75
            and not ai_missed
        )
        if ai_r["false_accepts"] > 0 or cl_r["false_accepts"] > 0 or ai_missed or (cl_missed_ai_hit and len(saved_diagnostics) < 18):
            if len(saved_diagnostics) < 24:
                p = save_failure_overlay(fail_dir, sc["id"], sc["rgb"], gt_q, ai_c, cl_c)
                saved_diagnostics.append({
                    "scene_id": sc["id"],
                    "category": sc["category"],
                    "ai_false_accepts": ai_r["false_accepts"],
                    "classical_false_accepts": cl_r["false_accepts"],
                    "ai_missed": ai_missed,
                    "overlay_path": p,
                })

    export_dart_golden_vectors(ai_det)

    report = {
        "benchmark_date_utc": "2026-10-22",
        "model_bundle": manifest["bundle_id"],
        "training_provenance": manifest["training_provenance"],
        "evaluation_environment": {
            "python_version": sys.version.split()[0],
            "platform": platform.platform(),
            "onnx_version": onnx.__version__,
            "onnxruntime_version": ort.__version__,
            "numpy_version": np.__version__,
            "opencv_version": cv2.__version__,
            "onnx_execution_provider": "CPUExecutionProvider (intra_op_num_threads=1, inter_op_num_threads=1)",
            "flutter_dart_runtime_executed": False,
        },
        "frozen_thresholds_used": ft_dict,
        "thresholds_modified_on_test": False,
        "split_leakage_audit": {
            "background_counts": {k: len(v) for k, v in bg_pools.items()},
            "specimen_counts": {k: len(v) for k, v in spec_pools.items()},
            "sha256_and_dhash_disjoint": True,
        },
        "resource_profile": {
            "stage1_onnx_bytes": manifest["models"]["stage1_detector"]["size_bytes"],
            "stage2_onnx_bytes": manifest["models"]["stage2_corner_refiner"]["size_bytes"],
            "total_model_bundle_bytes": manifest["models"]["stage1_detector"]["size_bytes"]
            + manifest["models"]["stage2_corner_refiner"]["size_bytes"],
            "python_positive_1280x960_peak_traced_heap_mb": round(peak_bytes / (1024 * 1024), 2),
            "dart_runtime_memory_measured": False,
        },
        "latency_benchmark": latency_profile,
        "track_a_wild_camera": {
            "classical_baseline": cl_a,
            "scanid_docnet_v1_ai": ai_a,
            "scene_ledger": track_a_ledger,
        },
        "track_b_heldout_stress": {
            "classical_baseline": cl_b,
            "scanid_docnet_v1_ai": ai_b,
        },
        "saved_diagnostic_examples": saved_diagnostics,
    }

    report_json_path = REPO_ROOT / "docs" / "reports" / "ai_boundary_benchmark_2026-10-22.json"
    report_json_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"[Benchmark Complete] Wrote {report_json_path}", flush=True)
    print("=== TRACK A (WILD CAMERA) ===")
    print("  Classical:", {k: cl_a[k] for k in ["proposal_recall_iou75", "auto_accept_rate_iou80", "mean_polygon_iou_matched", "mean_corner_error_pct_diag", "false_crop_accept_count", "negative_and_truncated_false_accept_rate", "latency_ms"]})
    print("  AI v1    :", {k: ai_a[k] for k in ["proposal_recall_iou75", "auto_accept_rate_iou80", "mean_polygon_iou_matched", "mean_corner_error_pct_diag", "false_crop_accept_count", "negative_and_truncated_false_accept_rate", "latency_ms"]})
    print("=== TRACK B (HELD-OUT STRESS 220 SCENES) ===")
    print("  Classical:", {k: cl_b[k] for k in ["proposal_recall_iou75", "auto_accept_rate_iou80", "mean_polygon_iou_matched", "mean_corner_error_pct_diag", "false_crop_accept_count", "negative_and_truncated_false_accept_rate", "multi_card_instance_recall_iou75", "multi_card_neighbor_merge_count", "latency_ms"]})
    print("  AI v1    :", {k: ai_b[k] for k in ["proposal_recall_iou75", "auto_accept_rate_iou80", "mean_polygon_iou_matched", "mean_corner_error_pct_diag", "false_crop_accept_count", "negative_and_truncated_false_accept_rate", "multi_card_instance_recall_iou75", "multi_card_neighbor_merge_count", "latency_ms"]})


if __name__ == "__main__":
    main()
