"""Clean-room PyTorch training, validation threshold calibration, and ONNX export.

Supports modular stages (`--stage 1`, `--stage 2`, `--export`, or `--all`) with
single-process OpenCV (`cv2.setNumThreads(0)`) to avoid Linux fork/OpenMP deadlocks.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict
import hashlib
import json
import os
import sys
import time

import cv2

cv2.setNumThreads(0)

import numpy as np
import onnx
import onnxruntime as ort
import torch
import torch.nn as nn
import torch.nn.functional as F

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))

from tool.ai.dataset_gen import (
    CATALOG_SPECS,
    apply_photometric_degradations,
    generate_stage1_sample,
    generate_stage2_sample,
    hamming64,
    load_disjoint_background_pools,
    load_disjoint_specimen_pools,
    polygon_iou,
    render_procedural_background,
    render_specimen_card_texture,
    sample_quad_homography,
    shrink_polygon_toward_centroid,
    warp_card_onto_scene,
)
from tool.ai.inference_pipeline import FrozenThresholds, TwoStageOnnxDetector
from tool.ai.models import (
    AdaptiveWingLoss,
    ScanIdStage1Detector,
    ScanIdStage2CornerRefiner,
    fuse_model_for_export,
)

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
MODELS_DIR = os.path.join(REPO_ROOT, "assets", "models")
CKPT_DIR = "/tmp/scanid_ai_ckpt"


def build_s1_dataset(base_seed: int, count: int, bg_pool, spec_pool):
    xs, ds, ws, ss = [], [], [], []
    for i in range(count):
        x, d, w, sc = generate_stage1_sample(base_seed + i, bg_pool, spec_pool, out_size=160)
        xs.append((x * 255.0).round().astype(np.uint8))
        ds.append(d.astype(np.float16))
        ws.append(w.astype(np.uint8))
        ss.append(sc.astype(np.float32))
    return np.stack(xs), np.stack(ds), np.stack(ws), np.stack(ss)


def build_s2_dataset(base_seed: int, count: int, bg_pool, spec_pool):
    xs, hs, os_arr, ms, qs = [], [], [], [], []
    for i in range(count):
        x, h, o, m, q = generate_stage2_sample(base_seed + i, bg_pool, spec_pool, out_size=128)
        xs.append((x * 255.0).round().astype(np.uint8))
        hs.append(h.astype(np.float16))
        os_arr.append(o.astype(np.float16))
        ms.append(m.astype(np.uint8))
        qs.append(q.astype(np.float32))
    return np.stack(xs), np.stack(hs), np.stack(os_arr), np.stack(ms), np.stack(qs)


def augment_s1_batch(
    x: torch.Tensor,
    dense: torch.Tensor,
    reg_w: torch.Tensor,
    rng: np.random.Generator,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    # [xmin - cx, ymin - cy, xmax - cx, ymax - cy] is 100% exact under H/V flips!
    if rng.random() < 0.5:
        x = torch.flip(x, dims=[3])
        dense = torch.flip(dense, dims=[3])
        reg_w = torch.flip(reg_w, dims=[3])
        old_dx0 = dense[:, 3].clone()
        old_dx1 = dense[:, 5].clone()
        dense[:, 3] = -old_dx1
        dense[:, 5] = -old_dx0

    if rng.random() < 0.5:
        x = torch.flip(x, dims=[2])
        dense = torch.flip(dense, dims=[2])
        reg_w = torch.flip(reg_w, dims=[2])
        old_dy0 = dense[:, 4].clone()
        old_dy1 = dense[:, 6].clone()
        dense[:, 4] = -old_dy1
        dense[:, 6] = -old_dy0

    if rng.random() < 0.6:
        gain = float(rng.uniform(0.86, 1.14))
        bias = float(rng.uniform(-0.06, 0.06))
        x = torch.clamp(x * gain + bias, 0.0, 1.0)

    return x, dense, reg_w


def augment_s2_batch(
    x: torch.Tensor,
    hmap: torch.Tensor,
    off: torch.Tensor,
    off_m: torch.Tensor,
    rng: np.random.Generator,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
    # Photometric jitter only (geometric orientation is already uniformly sampled 0..360 deg
    # in `dataset_gen.py`, keeping canonical TL/TR/BR/BL labels 100% consistent without flip swap!)
    if rng.random() < 0.7:
        gain = float(rng.uniform(0.84, 1.16))
        bias = float(rng.uniform(-0.07, 0.07))
        x = torch.clamp(x * gain + bias, 0.0, 1.0)
    if rng.random() < 0.35:
        # Per-channel white-balance shift
        wb = torch.tensor(
            [rng.uniform(0.90, 1.10), rng.uniform(0.92, 1.08), rng.uniform(0.90, 1.10)],
            dtype=x.dtype,
        ).view(1, 3, 1, 1)
        x = torch.clamp(x * wb, 0.0, 1.0)

    return x, hmap, off, off_m


def dice_loss(pred: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    inter = (pred * target).sum(dim=(2, 3))
    denom = pred.sum(dim=(2, 3)) + target.sum(dim=(2, 3)) + 1.0
    return (1.0 - (2.0 * inter + 1.0) / denom).mean()


def train_stage1(bg_pools, spec_pools) -> ScanIdStage1Detector:
    os.makedirs(CKPT_DIR, exist_ok=True)
    print("[Stage 1] Generating leak-free train (2,560) & val (512) scenes...", flush=True)
    t0 = time.time()
    tx, td, tw, ts = build_s1_dataset(100_000, 2560, bg_pools["train"], spec_pools["train"])
    vx, vd, vw, vs = build_s1_dataset(500_000, 512, bg_pools["val"], spec_pools["val"])
    print(f"[Stage 1] Dataset ready in {time.time() - t0:.1f}s", flush=True)

    torch.manual_seed(20261022)
    model = ScanIdStage1Detector()
    awing = AdaptiveWingLoss(fg_weight=12.0)
    bce = nn.BCELoss()

    epochs = 14
    batch_size = 32
    steps_per_epoch = len(tx) // batch_size
    opt = torch.optim.AdamW(model.parameters(), lr=3.5e-3, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(
        opt, max_lr=4.2e-3, epochs=epochs, steps_per_epoch=steps_per_epoch, pct_start=0.2
    )

    rng = np.random.default_rng(42)
    best_val = float("inf")
    best_state = None

    for ep in range(1, epochs + 1):
        ep_t0 = time.time()
        model.train()
        perm = rng.permutation(len(tx))
        tr_loss_acc = 0.0
        for s in range(steps_per_epoch):
            idx = perm[s * batch_size : (s + 1) * batch_size]
            bx = torch.from_numpy(tx[idx]).float() * (1.0 / 255.0)
            bd = torch.from_numpy(td[idx]).float()
            bw = torch.from_numpy(tw[idx]).float()
            bs = torch.from_numpy(ts[idx]).float()
            bx, bd, bw = augment_s1_batch(bx, bd, bw, rng)

            opt.zero_grad(set_to_none=True)
            pred_dense, pred_scene = model(bx)

            loss_center = awing(pred_dense[:, 0:1], bd[:, 0:1])
            loss_masks = bce(pred_dense[:, 1:3], bd[:, 1:3]) + 0.6 * dice_loss(pred_dense[:, 1:3], bd[:, 1:3])
            active_cnt = bw.sum() * 4.0 + 1e-4
            loss_off = (F.smooth_l1_loss(pred_dense[:, 3:7], bd[:, 3:7], reduction="none", beta=0.04) * bw).sum() / active_cnt
            loss_scene = bce(pred_scene, bs)
            loss = 1.5 * loss_center + 1.4 * loss_masks + 4.5 * loss_off + 0.8 * loss_scene

            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 3.0)
            opt.step()
            sched.step()
            tr_loss_acc += float(loss.item())

        model.eval()
        val_loss = 0.0
        val_mask_iou = 0.0
        n_vb = 0
        with torch.no_grad():
            for i in range(0, len(vx), 64):
                bx = torch.from_numpy(vx[i : i + 64]).float() * (1.0 / 255.0)
                bd = torch.from_numpy(vd[i : i + 64]).float()
                bw = torch.from_numpy(vw[i : i + 64]).float()
                bs = torch.from_numpy(vs[i : i + 64]).float()
                pd, ps = model(bx)
                lc = awing(pd[:, 0:1], bd[:, 0:1])
                lm = bce(pd[:, 1:3], bd[:, 1:3]) + 0.6 * dice_loss(pd[:, 1:3], bd[:, 1:3])
                lo = (F.smooth_l1_loss(pd[:, 3:7], bd[:, 3:7], reduction="none", beta=0.04) * bw).sum() / (bw.sum() * 4.0 + 1e-4)
                ls = bce(ps, bs)
                val_loss += float((1.5 * lc + 1.4 * lm + 4.5 * lo + 0.8 * ls).item())
                pm = (pd[:, 2] > 0.5).float()
                tm = (bd[:, 2] > 0.5).float()
                inter = (pm * tm).sum()
                union = ((pm + tm) > 0).float().sum() + 1e-5
                val_mask_iou += float((inter / union).item())
                n_vb += 1
        val_loss /= max(1, n_vb)
        val_mask_iou /= max(1, n_vb)
        if val_loss < best_val:
            best_val = val_loss
            best_state = {k: v.cpu().clone() for k, v in model.state_dict().items()}
        print(
            f"[Stage 1] Epoch {ep:02d}/{epochs} | train_loss={tr_loss_acc/steps_per_epoch:.4f} "
            f"| val_loss={val_loss:.4f} | val_mask_iou={val_mask_iou:.4f} ({time.time() - ep_t0:.1f}s)",
            flush=True,
        )

    model.load_state_dict(best_state)
    torch.save(best_state, os.path.join(CKPT_DIR, "stage1_best.pt"))
    return model.eval()


def train_stage2(bg_pools, spec_pools) -> ScanIdStage2CornerRefiner:
    os.makedirs(CKPT_DIR, exist_ok=True)
    print("[Stage 2] Generating leak-free train (3,840) & val (640) ROIs...", flush=True)
    t0 = time.time()
    tx, th, to, tm, tq = build_s2_dataset(200_000, 3840, bg_pools["train"], spec_pools["train"])
    vx, vh, vo, vm, vq = build_s2_dataset(600_000, 640, bg_pools["val"], spec_pools["val"])
    print(f"[Stage 2] Dataset ready in {time.time() - t0:.1f}s", flush=True)

    torch.manual_seed(20261023)
    model = ScanIdStage2CornerRefiner()
    awing_corners = AdaptiveWingLoss(fg_weight=16.0)
    awing_edge = AdaptiveWingLoss(fg_weight=8.0)
    bce = nn.BCELoss()

    epochs = 14
    batch_size = 32
    steps_per_epoch = len(tx) // batch_size
    opt = torch.optim.AdamW(model.parameters(), lr=3.5e-3, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(
        opt, max_lr=4.2e-3, epochs=epochs, steps_per_epoch=steps_per_epoch, pct_start=0.2
    )

    rng = np.random.default_rng(84)
    best_val = float("inf")
    best_state = None

    for ep in range(1, epochs + 1):
        ep_t0 = time.time()
        model.train()
        perm = rng.permutation(len(tx))
        tr_loss_acc = 0.0
        for s in range(steps_per_epoch):
            idx = perm[s * batch_size : (s + 1) * batch_size]
            bx = torch.from_numpy(tx[idx]).float() * (1.0 / 255.0)
            bh = torch.from_numpy(th[idx]).float()
            bo = torch.from_numpy(to[idx]).float()
            bm = torch.from_numpy(tm[idx]).float()
            bq = torch.from_numpy(tq[idx]).float()
            bx, bh, bo, bm = augment_s2_batch(bx, bh, bo, bm, rng)

            opt.zero_grad(set_to_none=True)
            ph, po, pq = model(bx)

            loss_ordered = awing_corners(ph[:, 0:4], bh[:, 0:4])
            loss_any_c = awing_corners(ph[:, 4:5], bh[:, 4:5])
            loss_edge = awing_edge(ph[:, 5:6], bh[:, 5:6])
            bm2 = torch.repeat_interleave(bm, 2, dim=1)
            loss_off = (F.smooth_l1_loss(po, bo, reduction="none", beta=0.05) * bm2).sum() / (bm2.sum() + 1e-4)
            loss_qual = bce(pq, bq)
            loss = 1.6 * loss_ordered + 1.8 * loss_any_c + 1.0 * loss_edge + 2.5 * loss_off + 1.2 * loss_qual

            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 3.0)
            opt.step()
            sched.step()
            tr_loss_acc += float(loss.item())

        model.eval()
        val_loss = 0.0
        val_acc_qual = 0.0
        n_vb = 0
        with torch.no_grad():
            for i in range(0, len(vx), 64):
                bx = torch.from_numpy(vx[i : i + 64]).float() * (1.0 / 255.0)
                bh = torch.from_numpy(vh[i : i + 64]).float()
                bo = torch.from_numpy(vo[i : i + 64]).float()
                bm = torch.from_numpy(vm[i : i + 64]).float()
                bq = torch.from_numpy(vq[i : i + 64]).float()
                ph, po, pq = model(bx)
                lo_ord = awing_corners(ph[:, 0:4], bh[:, 0:4])
                lo_any = awing_corners(ph[:, 4:5], bh[:, 4:5])
                le = awing_edge(ph[:, 5:6], bh[:, 5:6])
                bm2 = torch.repeat_interleave(bm, 2, dim=1)
                lo = (F.smooth_l1_loss(po, bo, reduction="none", beta=0.05) * bm2).sum() / (bm2.sum() + 1e-4)
                lq = bce(pq, bq)
                val_loss += float((1.6 * lo_ord + 1.8 * lo_any + 1.0 * le + 2.5 * lo + 1.2 * lq).item())
                val_acc_qual += float(((pq[:, 0] > 0.5) == (bq[:, 0] > 0.5)).float().mean().item())
                n_vb += 1
        val_loss /= max(1, n_vb)
        val_acc_qual /= max(1, n_vb)
        if val_loss < best_val:
            best_val = val_loss
            best_state = {k: v.cpu().clone() for k, v in model.state_dict().items()}
        print(
            f"[Stage 2] Epoch {ep:02d}/{epochs} | train_loss={tr_loss_acc/steps_per_epoch:.4f} "
            f"| val_loss={val_loss:.4f} | val_valid_acc={val_acc_qual:.4f} ({time.time() - ep_t0:.1f}s)",
            flush=True,
        )

    model.load_state_dict(best_state)
    torch.save(best_state, os.path.join(CKPT_DIR, "stage2_best.pt"))
    return model.eval()


def export_and_verify_onnx(
    model: nn.Module,
    dummy_shape: tuple[int, ...],
    output_names: list[str],
    out_path: str,
) -> dict:
    fused = fuse_model_for_export(model)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    x = torch.rand(*dummy_shape)
    with torch.no_grad():
        ref_outs = fused(x)
        if not isinstance(ref_outs, tuple):
            ref_outs = (ref_outs,)

    torch.onnx.export(
        fused,
        x,
        out_path,
        input_names=["input"],
        output_names=output_names,
        opset_version=13,
        do_constant_folding=True,
        dynamo=False,
    )
    om = onnx.load(out_path)
    onnx.checker.check_model(om)
    sess = ort.InferenceSession(out_path, providers=["CPUExecutionProvider"])
    ort_outs = sess.run(None, {"input": x.numpy()})
    max_diff = max(float(np.abs(a.numpy() - b).max()) for a, b in zip(ref_outs, ort_outs))
    assert max_diff < 1e-5, f"ONNX export parity error: {max_diff}"

    raw_bytes = open(out_path, "rb").read()
    sha256 = hashlib.sha256(raw_bytes).hexdigest()
    ops = sorted(set(n.op_type for n in om.graph.node))
    n_params = int(sum(p.numel() for p in fused.parameters()))
    return {
        "file": os.path.relpath(out_path, REPO_ROOT).replace("\\", "/"),
        "size_bytes": len(raw_bytes),
        "sha256": sha256,
        "parameters": n_params,
        "opset": 13,
        "operators": ops,
        "max_pytorch_ort_abs_diff": max_diff,
    }


def calibrate_thresholds_on_validation(
    s1_path: str,
    s2_path: str,
    bg_val,
    spec_val,
) -> tuple[FrozenThresholds, dict]:
    print("[Validation Calibration] Building 160 end-to-end validation scenes...", flush=True)
    val_scenes = []
    for idx in range(160):
        rng = np.random.default_rng(700_000 + idx)
        sw, sh = 640, 480
        bg = render_procedural_background(rng, sw, sh, bg_val)
        bg_l = float(bg.mean())
        cat = idx % 8
        if cat == 0:
            scene = apply_photometric_degradations(bg, rng, "random")
            val_scenes.append(("negative", scene, []))
        elif cat == 1:
            scene = bg.copy()
            mask = np.zeros((sh, sw), dtype=np.float32)
            mask[70:410, 420:482] = 1.0
            mask = cv2.GaussianBlur(mask, (9, 9), 2.5)
            scene = np.clip(scene.astype(np.float32) * (1.0 - 0.38 * mask[:, :, None]), 0, 255).astype(np.uint8)
            val_scenes.append(("negative", scene, []))
        elif cat == 2:
            sp = CATALOG_SPECS[idx % len(CATALOG_SPECS)]
            tex, al = render_specimen_card_texture(rng, sp[0], sp[1], sp[2], bg_l, spec_val)
            q_px = sample_quad_homography(rng, sp[1], sw, sh, (0.35, 0.72), force_truncated=True)
            scene = warp_card_onto_scene(bg, tex, al, q_px, rng)
            scene = apply_photometric_degradations(scene, rng, "random")
            val_scenes.append(("truncated", scene, []))
        elif cat in (3, 4, 5):
            sp = CATALOG_SPECS[idx % len(CATALOG_SPECS)]
            tex, al = render_specimen_card_texture(rng, sp[0], sp[1], sp[2], bg_l, spec_val)
            q_px = None
            for _ in range(12):
                q_px = sample_quad_homography(rng, sp[1], sw, sh, (0.12, 0.65), max_persp=0.24)
                if q_px is not None:
                    break
            if q_px is None:
                continue
            scene = warp_card_onto_scene(bg, tex, al, q_px, rng)
            mode = ["random", "glare", "low_light"][cat - 3]
            scene = apply_photometric_degradations(scene, rng, mode)
            val_scenes.append(("single", scene, [q_px / np.array([sw - 1, sh - 1], dtype=np.float32)]))
        else:
            placed = []
            scene = bg
            for _ in range(14):
                if len(placed) >= 2:
                    break
                sp = CATALOG_SPECS[int(rng.integers(0, len(CATALOG_SPECS)))]
                q_px = sample_quad_homography(rng, sp[1], sw, sh, (0.09, 0.26), max_persp=0.18)
                if q_px is None:
                    continue
                if any(polygon_iou(shrink_polygon_toward_centroid(q_px, 1.08), shrink_polygon_toward_centroid(p, 1.08)) > 0 for p in placed):
                    continue
                tex, al = render_specimen_card_texture(rng, sp[0], sp[1], sp[2], bg_l, spec_val)
                scene = warp_card_onto_scene(scene, tex, al, q_px, rng)
                placed.append(q_px)
            scene = apply_photometric_degradations(scene, rng, "random")
            val_scenes.append(("multi", scene, [p / np.array([sw - 1, sh - 1], dtype=np.float32) for p in placed]))

    grid_candidates = [
        FrozenThresholds(
            accept_roi_valid=rv,
            accept_four_visible=rv,
            accept_min_corner_peak=mcp,
            accept_mean_corner_peak=mcp + 0.14,
            accept_min_edge_support=mes,
            accept_mean_edge_support=mes + 0.12,
        )
        for rv in (0.55, 0.65, 0.72)
        for mcp in (0.34, 0.42, 0.50)
        for mes in (0.24, 0.32)
    ]

    det = TwoStageOnnxDetector(s1_path, s2_path, FrozenThresholds())
    cached_detections = [(kind, gt_quads, scene.shape[1], scene.shape[0], det.detect(scene)) for kind, scene, gt_quads in val_scenes]

    best_t = FrozenThresholds()
    best_objective = -1e9
    best_summary = {}
    from tool.ai.inference_pipeline import classify_candidate_verdict

    for cand_t in grid_candidates:
        false_accepts = 0
        tp_accept = 0
        tp_any = 0
        gt_total = 0
        iou_sum = 0.0

        for kind, gt_quads, sw_i, sh_i, res in cached_detections:
            accepted = [
                c
                for c in res.candidates
                if classify_candidate_verdict(c, cand_t, None, sw_i, sh_i)[0] == "accepted"
            ]
            if kind in ("negative", "truncated"):
                false_accepts += len(accepted)
            else:
                for c in accepted:
                    best_gt_iou = max((polygon_iou(gq, c.corners) for gq in gt_quads), default=0.0)
                    if best_gt_iou < 0.78:
                        false_accepts += 1
                for gq in gt_quads:
                    gt_total += 1
                    best_iou_acc = max((polygon_iou(gq, c.corners) for c in accepted), default=0.0)
                    best_iou_all = max((polygon_iou(gq, c.corners) for c in res.candidates), default=0.0)
                    if best_iou_acc >= 0.80:
                        tp_accept += 1
                        iou_sum += best_iou_acc
                    if best_iou_all >= 0.75:
                        tp_any += 1

        false_accept_rate = false_accepts / max(1, len(val_scenes))
        accept_recall = tp_accept / max(1, gt_total)
        proposal_recall = tp_any / max(1, gt_total)
        mean_iou = iou_sum / max(1, tp_accept)
        obj = accept_recall + 0.35 * proposal_recall + 0.25 * mean_iou - 8.0 * false_accept_rate
        if obj > best_objective:
            best_objective = obj
            best_t = cand_t
            best_summary = {
                "val_scenes": len(val_scenes),
                "val_gt_documents": gt_total,
                "val_accept_recall_iou80": round(accept_recall, 4),
                "val_proposal_recall_iou75": round(proposal_recall, 4),
                "val_accepted_mean_iou": round(mean_iou, 4),
                "val_false_crop_accept_rate": round(false_accept_rate, 4),
                "val_false_crop_count": false_accepts,
            }

    print(f"[Validation Calibration] Frozen thresholds selected on val ONLY: {best_summary}", flush=True)
    return best_t, best_summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", choices=["1", "2", "export", "all"], default="all")
    args = parser.parse_args()

    torch.set_num_threads(2)
    bg_pools = load_disjoint_background_pools()
    spec_pools = load_disjoint_specimen_pools()

    for pool_name, pools in [("background", bg_pools), ("specimen", spec_pools)]:
        for s1 in ("train", "val", "test"):
            for s2 in ("train", "val", "test"):
                if s1 >= s2:
                    continue
                for a in pools[s1]:
                    for b in pools[s2]:
                        assert a.sha256 != b.sha256, f"Exact leak in {pool_name}: {a.asset_id}"
                        assert hamming64(a.dhash, b.dhash) > 10, f"Near-dup leak in {pool_name}: {a.asset_id} vs {b.asset_id}"
    print(
        f"[Split Audit] Verified ZERO cross-split leakage | "
        f"bg={ {k: len(v) for k, v in bg_pools.items()} } | "
        f"specimens={ {k: len(v) for k, v in spec_pools.items()} }",
        flush=True,
    )

    if args.stage in ("1", "all"):
        train_stage1(bg_pools, spec_pools)
    if args.stage in ("2", "all"):
        train_stage2(bg_pools, spec_pools)
    if args.stage in ("export", "all"):
        m1 = ScanIdStage1Detector()
        m1.load_state_dict(torch.load(os.path.join(CKPT_DIR, "stage1_best.pt"), map_location="cpu", weights_only=True))
        m1.eval()

        m2 = ScanIdStage2CornerRefiner()
        m2.load_state_dict(torch.load(os.path.join(CKPT_DIR, "stage2_best.pt"), map_location="cpu", weights_only=True))
        m2.eval()

        s1_onnx = os.path.join(MODELS_DIR, "scanid_stage1_det_v1.onnx")
        s2_onnx = os.path.join(MODELS_DIR, "scanid_stage2_corners_v1.onnx")
        meta1 = export_and_verify_onnx(m1, (1, 3, 160, 160), ["dense_map", "scene_prob"], s1_onnx)
        meta2 = export_and_verify_onnx(m2, (1, 3, 128, 128), ["corner_heatmaps", "corner_offsets", "roi_quality"], s2_onnx)

        frozen_t, val_summary = calibrate_thresholds_on_validation(
            s1_onnx, s2_onnx, bg_pools["val"], spec_pools["val"]
        )

        manifest = {
            "schema_version": 1,
            "bundle_id": "scanid-docnet-v1",
            "created_utc": "2026-10-22",
            "license": "MIT",
            "training_provenance": {
                "clean_room_from_scratch": True,
                "external_pretrained_weights_used": False,
                "framework": f"PyTorch {torch.__version__}",
                "onnx_binary_producer": f"pytorch {torch.__version__.split('+')[0]} (ir_version=7, opset=13)",
                "export_tool": "torch.onnx.export(opset_version=13, do_constant_folding=True, dynamo=False) with BatchNorm2d folded into Conv2d",
                "export_format": "ONNX Opset 13 (BatchNorm folded)",
                "background_sources": [
                    {"name": "scikit-image data", "license": "BSD-3-Clause"},
                    {"name": "OpenCV samples/data", "license": "Apache-2.0"},
                    {"name": "First-party procedural surfaces", "license": "MIT"},
                ],
                "document_sources": [
                    {"name": "PassportEye official non-PII specimens (UTO/SPECIMEN)", "license": "MIT"},
                    {"name": "First-party procedural Iraqi/ISO catalog specimens", "license": "MIT"},
                ],
                "split_disjoint_verified": True,
                "personal_pii_included": False,
            },
            "models": {
                "stage1_detector": meta1,
                "stage2_corner_refiner": meta2,
            },
            "frozen_thresholds": asdict(frozen_t),
            "validation_calibration_summary": val_summary,
        }
        manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
        manifest_path = os.path.join(MODELS_DIR, "MODEL_MANIFEST.json")
        with open(manifest_path, "wb") as f:
            f.write(manifest_bytes)
        print(f"[Export Complete] Wrote {manifest_path}", flush=True)
        print(json.dumps(manifest, indent=2), flush=True)


if __name__ == "__main__":
    main()
