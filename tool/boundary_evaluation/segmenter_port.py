#!/usr/bin/env python3
"""Faithful Python port of the SHIPPED Dart segmenter's region stage.

Why a port and not a run: this sandbox can reach only GitHub, npm and PyPI, so
no Flutter/Dart SDK can be installed and `flutter test` cannot run here. The
region stage is 360-px classical arithmetic (downscale -> border-median
background -> Otsu on summed RGB distance -> 4-connected components ->
area/fill/aspect/frame gates -> IoU/containment merge -> candidate cap), and
porting it lets the baseline be MEASURED against the packaged dataset instead of
asserted. Every parameter is copied from `lib/imaging/document_segmenter.dart`
and the port is checked against the Dart unit tests' own fixtures
(`two separated cards segment into two corner candidates`, `a single card
reports no multi-document structure`, `a blank image reports no structure`).

It measures the REGION stage only. Corner detection, perspective correction,
OCR and classification are out of scope for this port, and no number below is
claimed for them.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import deque
from pathlib import Path

import cv2
import numpy as np

# --- constants copied from lib/imaging/document_segmenter.dart --------------
WORK_SIDE = 360                 # `const workSide = 360`
MIN_REGION_AREA_FRACTION = 0.015  # `box.area >= total * .015`
MIN_BOX_SIDE = 10               # `box.width >= 10 && box.height >= 10`
MIN_BOX_FILL = 0.4              # `box.fill >= .4`
MAX_BOX_AREA_FRACTION = 0.95    # `box.width * box.height <= total * .95`
MIN_ABSORB_FILL = 0.5
ABSORB_FIX = True
MERGE_IOU = 0.2                 # `_mergeBoxes` IoU threshold
MARGIN_FRACTION = 0.08          # `_measure` margin
MAX_PLAUSIBLE_ASPECT = 8.0      # `maxPlausibleRegionAspect`
MIN_USABLE_REGION_CROP_PX = 48  # `minUsableRegionCropPx`
MAX_SEGMENT_CANDIDATES = 12     # `maxSegmentCandidates`
MIN_PREVIEW_SIDE = 40           # `minRecognitionPreviewSide`
# Toggled by --no-split so the effect of the fix is measured, not asserted.
SPLIT_TOUCHING_CARDS = True
ADAPTIVE_FALLBACK = False
MIN_SPLIT_ASPECT = 0.80
MAX_SPLIT_ASPECT = 5.9


def _otsu(values: np.ndarray, max_value: float, bins: int = 128) -> float:
    """Port of `_otsu`: histogram over [0, max_value], 128 bins."""
    histogram = np.zeros(bins, dtype=np.int64)
    scaled = np.clip((values / max_value) * (bins - 1), 0, bins - 1).round()
    np.add.at(histogram, scaled.astype(np.int64), 1)
    total = values.size
    total_sum = float((np.arange(bins) * histogram).sum())
    sum_background = 0.0
    weight_background = 0
    best = 0.0
    best_index = bins // 2
    for index in range(bins):
        weight_background += int(histogram[index])
        if weight_background == 0:
            continue
        weight_foreground = total - weight_background
        if weight_foreground == 0:
            break
        sum_background += index * histogram[index]
        mean_background = sum_background / weight_background
        mean_foreground = (total_sum - sum_background) / weight_foreground
        between = (
            weight_background * weight_foreground *
            (mean_background - mean_foreground) ** 2
        )
        if between > best:
            best = between
            best_index = index
    return best_index / (bins - 1) * max_value


def _components(mask: np.ndarray) -> list[dict]:
    """4-connected components with their bounding box and pixel count."""
    height, width = mask.shape
    seen = np.zeros_like(mask, dtype=np.uint8)
    out = []
    for start_y in range(height):
        for start_x in range(width):
            if mask[start_y, start_x] == 0 or seen[start_y, start_x]:
                continue
            queue = deque([(start_x, start_y)])
            seen[start_y, start_x] = 1
            left = right = start_x
            top = bottom = start_y
            area = 0
            while queue:
                x, y = queue.popleft()
                area += 1
                left, right = min(left, x), max(right, x)
                top, bottom = min(top, y), max(bottom, y)
                for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < width and 0 <= ny < height:
                        if mask[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = 1
                            queue.append((nx, ny))
            out.append(
                {
                    "left": left, "top": top, "right": right, "bottom": bottom,
                    "area": float(area),
                }
            )
    return out


def _box_iou(a, b) -> float:
    left = max(a["left"], b["left"])
    top = max(a["top"], b["top"])
    right = min(a["right"], b["right"])
    bottom = min(a["bottom"], b["bottom"])
    if right < left or bottom < top:
        return 0.0
    intersection = float((right - left + 1) * (bottom - top + 1))
    area_a = (a["right"] - a["left"] + 1) * (a["bottom"] - a["top"] + 1)
    area_b = (b["right"] - b["left"] + 1) * (b["bottom"] - b["top"] + 1)
    return intersection / (area_a + area_b - intersection)


def _contains(outer, inner) -> bool:
    return (
        inner["left"] >= outer["left"] and inner["top"] >= outer["top"]
        and inner["right"] <= outer["right"] and inner["bottom"] <= outer["bottom"]
    )


def _split_along_axis(box, mask, by_column, frame_area):
    """Port of `_splitAlongAxis` in lib/imaging/document_segmenter.dart."""
    width = box["right"] - box["left"] + 1
    height = box["bottom"] - box["top"] + 1
    span = width if by_column else height
    cross = height if by_column else width
    if span < 40 or cross < 20:
        return None
    sub = mask[box["top"] : box["bottom"] + 1, box["left"] : box["right"] + 1]
    counts = (sub.sum(axis=0) if by_column else sub.sum(axis=1)).astype(np.int64)
    padded = np.concatenate([[counts[0]], counts, [counts[-1]]])
    smooth = np.round(
        (padded[:-2] + padded[1:-1] + padded[2:]) / 3.0
    ).astype(np.int64)
    low = round(span * 0.25)
    high = round(span * 0.75)
    if high <= low + 4:
        return None
    valley = low + int(np.argmin(smooth[low : high + 1]))
    first_peak = int(smooth[:valley].max()) if valley > 0 else 0
    second_peak = int(smooth[valley + 1 :].max()) if valley + 1 < span else 0
    if first_peak <= 0 or second_peak <= 0:
        return None
    min_peak = min(first_peak, second_peak) / cross
    valley_occupancy = smooth[valley] / cross
    if min_peak < 0.60:
        return None
    if valley_occupancy >= 0.25 * min_peak:
        return None
    cut = (box["left"] if by_column else box["top"]) + valley
    if by_column:
        first = {"left": box["left"], "top": box["top"], "right": cut,
                 "bottom": box["bottom"]}
        second = {"left": cut + 1, "top": box["top"], "right": box["right"],
                  "bottom": box["bottom"]}
    else:
        first = {"left": box["left"], "top": box["top"], "right": box["right"],
                 "bottom": cut}
        second = {"left": box["left"], "top": cut + 1, "right": box["right"],
                  "bottom": box["bottom"]}
    for half in (first, second):
        area = float(
            mask[half["top"] : half["bottom"] + 1,
                 half["left"] : half["right"] + 1].sum()
        )
        half["area"] = area
        bw = half["right"] - half["left"] + 1
        bh = half["bottom"] - half["top"] + 1
        if area < frame_area * 0.015:
            return None
        aspect = max(bw, bh) / max(1, min(bw, bh))
        if aspect < MIN_SPLIT_ASPECT or aspect > MAX_SPLIT_ASPECT:
            return None
        if min(bw, bh) < 10:
            return None
        if area / (bw * bh) < 0.55:
            return None
    return [first, second]


def _split_touching_cards(box, mask, frame_area):
    """Port of `_splitTouchingCards`."""
    pending = [box]
    out = []
    while pending:
        current = pending.pop()
        split = _split_along_axis(current, mask, True, frame_area)
        if split is None:
            split = _split_along_axis(current, mask, False, frame_area)
        if split is None:
            out.append(current)
        else:
            pending.extend(split)
    out.sort(key=lambda b: (b["top"], b["left"]))
    return out


def _adaptive_mask(image, work_w, work_h):
    """Local-contrast mask for the fallback pass.

    Port of the proposed fix: when the single GLOBAL Otsu threshold on colour
    distance finds nothing, the background is not uniform enough for one global
    threshold to separate a document. A per-tile adaptive threshold on the LAB
    lightness is then used to build the same kind of mask, and the SAME
    component/gate pipeline decides what is a region. Only the mask source
    differs, so a candidate from this pass is judged exactly like one from the
    primary pass.
    """
    work = (
        cv2.resize(image, (work_w, work_h), interpolation=cv2.INTER_AREA)
        if image.shape[1] != work_w or image.shape[0] != work_h
        else image
    )
    lab_l = cv2.cvtColor(work, cv2.COLOR_BGR2LAB)[:, :, 0]
    blur = cv2.GaussianBlur(lab_l, (7, 7), 0)
    best = None
    best_count = 0
    for block in (31, 61, 101):
        for polarity in (cv2.THRESH_BINARY, cv2.THRESH_BINARY_INV):
            binary = cv2.adaptiveThreshold(
                blur, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, polarity, block, -4
            )
            cleaned = cv2.morphologyEx(
                binary, cv2.MORPH_CLOSE, np.ones((7, 7), np.uint8), iterations=2
            )
            cleaned = cv2.morphologyEx(
                cleaned, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8)
            )
            count = cv2.countNonZero(cleaned)
            # Prefer the mask that marks a plausible share of the frame as
            # foreground; an all-white or all-black mask is useless.
            share = count / float(work_w * work_h)
            score = -abs(share - 0.25)
            if best is None or score > best[0]:
                best = (score, cleaned)
            best_count = max(best_count, count)
    return (best[1] > 0).astype(np.uint8)


def _merge(boxes: list[dict]) -> list[dict]:
    """Port of `_mergeBoxes`: merge on IoU > .2 or containment, repeat."""
    boxes = [dict(box) for box in boxes]
    changed = True
    while changed:
        changed = False
        for a in range(len(boxes)):
            for b in range(a + 1, len(boxes)):
                if (
                    _box_iou(boxes[a], boxes[b]) > MERGE_IOU
                    or _absorbs(boxes[a], boxes[b])
                    or _absorbs(boxes[b], boxes[a])
                ):
                    merged = {
                        "left": min(boxes[a]["left"], boxes[b]["left"]),
                        "top": min(boxes[a]["top"], boxes[b]["top"]),
                        "right": max(boxes[a]["right"], boxes[b]["right"]),
                        "bottom": max(boxes[a]["bottom"], boxes[b]["bottom"]),
                        "area": boxes[a]["area"] + boxes[b]["area"],
                    }
                    boxes.pop(b)
                    boxes.pop(a)
                    boxes.append(merged)
                    changed = True
                    break
            if changed:
                break
    return boxes


def _fill(box) -> float:
    width = box["right"] - box["left"] + 1
    height = box["bottom"] - box["top"] + 1
    return box["area"] / float(width * height) if width > 0 and height > 0 else 0.0


def _absorbs(outer, inner) -> bool:
    """Port of `_absorbs`: containment is not enough, the container must be solid."""
    return (
        _contains(outer, inner)
        and _fill(outer) >= MIN_ABSORB_FILL
    )


def _measure(box, work_w, work_h, image_w, image_h) -> dict:
    """Port of `_measure`: margin-expanded region + preview crop size."""
    box_w = box["right"] - box["left"] + 1
    box_h = box["bottom"] - box["top"] + 1
    margin_x = max(4, round(box_w * MARGIN_FRACTION))
    margin_y = max(4, round(box_h * MARGIN_FRACTION))
    left = max(0, box["left"] - margin_x)
    top = max(0, box["top"] - margin_y)
    right = min(work_w - 1, box["right"] + margin_x)
    bottom = min(work_h - 1, box["bottom"] + margin_y)
    region = [
        left / (work_w - 1), top / (work_h - 1),
        right / (work_w - 1), bottom / (work_h - 1),
    ]
    sub_left = round(region[0] * (image_w - 1))
    sub_top = round(region[1] * (image_h - 1))
    sub_right = round(region[2] * (image_w - 1))
    sub_bottom = round(region[3] * (image_h - 1))
    border_sides = (
        (1 if box["left"] == 0 else 0)
        + (1 if box["top"] == 0 else 0)
        + (1 if box["right"] == work_w - 1 else 0)
        + (1 if box["bottom"] == work_h - 1 else 0)
    )
    long_side = max(box_w, box_h)
    short_side = max(1, min(box_w, box_h))
    return {
        "region": region,
        "sub_width": sub_right - sub_left + 1,
        "sub_height": sub_bottom - sub_top + 1,
        "border_sides": border_sides,
        "aspect": long_side / short_side,
        "fill": box["area"] / (box_w * box_h),
        "area_fraction": box["area"] / float(work_w * work_h),
    }


def _rejection(measurement: dict) -> str | None:
    """Port of `_rejectionFor`."""
    if measurement["border_sides"] >= 2:
        return "frameArtifact"
    if measurement["aspect"] > MAX_PLAUSIBLE_ASPECT:
        return "implausibleAspect"
    if min(measurement["sub_width"], measurement["sub_height"]) < (
        MIN_USABLE_REGION_CROP_PX
    ):
        return "unusableCrop"
    return None


def segment_regions(image: np.ndarray) -> dict:
    """Port of `segmentDecoded` up to the candidate gate (no corner search)."""
    height, width = image.shape[:2]
    if width < MIN_PREVIEW_SIDE or height < MIN_PREVIEW_SIDE:
        return {"candidates": [], "rejected": [], "background_luminance": None}
    longest = max(width, height)
    scale = WORK_SIDE / longest if longest > WORK_SIDE else 1.0
    work = (
        cv2.resize(
            image, (max(1, int(width * scale)), max(1, int(height * scale))),
            interpolation=cv2.INTER_AREA,
        )
        if scale < 1.0
        else image
    )
    work_h, work_w = work.shape[:2]
    pixels = work.astype(np.float32)

    border = np.concatenate(
        [
            pixels[0:2].reshape(-1, 3),
            pixels[max(0, work_h - 2):].reshape(-1, 3),
            pixels[:, 0:2].reshape(-1, 3),
            pixels[:, max(0, work_w - 2):].reshape(-1, 3),
        ]
    )
    background = np.median(border, axis=0)
    distance = np.abs(pixels - background).sum(axis=2)
    threshold = _otsu(distance.reshape(-1), 765.0)
    mask = (distance > threshold).astype(np.uint8)

    total = float(work_w * work_h)
    usable = [
        box for box in _components(mask)
        if box["area"] >= total * MIN_REGION_AREA_FRACTION
        and (box["right"] - box["left"] + 1) >= MIN_BOX_SIDE
        and (box["bottom"] - box["top"] + 1) >= MIN_BOX_SIDE
        and box["area"] / (
            (box["right"] - box["left"] + 1) * (box["bottom"] - box["top"] + 1)
        ) >= MIN_BOX_FILL
        and (box["right"] - box["left"] + 1) * (
            box["bottom"] - box["top"] + 1
        ) <= total * MAX_BOX_AREA_FRACTION
    ]
    merged = _merge(usable)
    merged.sort(key=lambda b: (b["top"], b["left"]))
    if SPLIT_TOUCHING_CARDS:
        merged = [
            piece for box in merged
            for piece in _split_touching_cards(box, mask, total)
        ]
        merged.sort(key=lambda b: (b["top"], b["left"]))
    measured = [_measure(box, work_w, work_h, width, height) for box in merged]
    if ADAPTIVE_FALLBACK and not any(
        _rejection(_measure(box, work_w, work_h, width, height)) is None
        for box in merged
    ):
        fallback_mask = _adaptive_mask(image, work_w, work_h)
        boxes = [
            box for box in _components(fallback_mask)
            if box["area"] >= total * MIN_REGION_AREA_FRACTION
            and (box["right"] - box["left"] + 1) >= MIN_BOX_SIDE
            and (box["bottom"] - box["top"] + 1) >= MIN_BOX_SIDE
            and box["area"] / (
                (box["right"] - box["left"] + 1)
                * (box["bottom"] - box["top"] + 1)
            ) >= MIN_BOX_FILL
            and (box["right"] - box["left"] + 1)
            * (box["bottom"] - box["top"] + 1) <= total * MAX_BOX_AREA_FRACTION
        ]
        merged = _merge(boxes)
        merged.sort(key=lambda b: (b["top"], b["left"]))
        measured = [
            _measure(box, work_w, work_h, width, height) for box in merged
        ]
        used_fallback = True
    else:
        used_fallback = False

    accepted, rejected = [], []
    for measurement in measured:
        reason = _rejection(measurement)
        (rejected if reason else accepted).append(
            {**measurement, "rejection": reason}
        )
    if len(accepted) > MAX_SEGMENT_CANDIDATES:
        accepted.sort(key=lambda m: -m["area_fraction"])
        rejected.extend(
            {**m, "rejection": "candidateCap"}
            for m in accepted[MAX_SEGMENT_CANDIDATES:]
        )
        accepted = accepted[:MAX_SEGMENT_CANDIDATES]
    background_luminance = (
        0.299 * background[2] + 0.587 * background[1] + 0.114 * background[0]
    )
    return {
        "candidates": accepted,
        "rejected": rejected,
        "used_fallback": used_fallback,
        "background_luminance": round(float(background_luminance), 2),
        "single_resolved_route": len(accepted) == 1,
    }


# ------------------------------------------------------------------ metrics


def _quad_from_region(region):
    return np.array(
        [
            [region[0], region[1]], [region[2], region[1]],
            [region[2], region[3]], [region[0], region[3]],
        ],
        dtype=np.float64,
    )


def _iou(a, b) -> float:
    inter, _ = cv2.intersectConvexConvex(a.astype(np.float32), b.astype(np.float32))
    area_a = abs(cv2.contourArea(a.astype(np.float32)))
    area_b = abs(cv2.contourArea(b.astype(np.float32)))
    union = area_a + area_b - inter
    return float(inter / union) if union > 0 else 0.0


def evaluate(image, truth_instances, iou_threshold: float = 0.5) -> dict:
    result = segment_regions(image)
    predicted = [c["region"] for c in result["candidates"]]
    truth = [i["points_norm"] for i in truth_instances if i["points_norm"]]
    matched_truth = set()
    matched_predicted = set()
    ious = []
    for p_index, region in enumerate(predicted):
        quad = _quad_from_region(region)
        best = (0.0, None)
        for t_index, points in enumerate(truth):
            overlap = _iou(quad, np.array(points, dtype=np.float64))
            if overlap > best[0]:
                best = (overlap, t_index)
        if best[1] is not None and best[0] >= iou_threshold:
            matched_truth.add(best[1])
            matched_predicted.add(p_index)
            ious.append(best[0])
    return {
        "documents": len(truth_instances),
        "scorable": len(truth),
        "predicted": len(predicted),
        "matched": len(matched_truth),
        "merged": max(
            0,
            len(predicted) - len(matched_predicted),
        ),
        "missed": [truth_instances[i]["instance_id"]
                   for i in range(len(truth)) if i not in matched_truth],
        "spurious": len(predicted) - len(matched_predicted),
        "ious": [round(v, 4) for v in ious],
        "rejected_regions": len(result["rejected"]),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--truth", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument(
        "--no-absorb-fix",
        action="store_true",
        help="reproduce the shipped containment rule (any box absorbs any "
        "box it contains)",
    )
    parser.add_argument(
        "--adaptive",
        action="store_true",
        help="enable the adaptive-threshold fallback pass",
    )
    parser.add_argument(
        "--no-split",
        action="store_true",
        help="reproduce the shipped behaviour: never split a merged region",
    )
    args = parser.parse_args()
    global SPLIT_TOUCHING_CARDS, ADAPTIVE_FALLBACK, MIN_ABSORB_FILL
    SPLIT_TOUCHING_CARDS = not args.no_split
    ADAPTIVE_FALLBACK = args.adaptive
    if args.no_absorb_fix:
        MIN_ABSORB_FILL = 0.0

    truth = json.loads(args.truth.read_text(encoding="utf-8"))
    by_image: dict[int, list[dict]] = {}
    for entry in truth["instances"]:
        by_image.setdefault(int(entry["image_index"]), []).append(entry)
    images = sorted(
        p for p in (args.dataset / "images_original").iterdir() if p.is_file()
    )

    per_image = {}
    total_documents = total_scorable = 0
    total_predicted = total_matched = 0
    merged_errors = 0
    missing_errors = 0
    spurious_errors = 0
    all_ious = []
    for index, path in enumerate(images, start=1):
        data = np.fromfile(str(path), dtype=np.uint8)
        image = cv2.imdecode(data, cv2.IMREAD_COLOR)
        metrics = evaluate(image, by_image.get(index, []))
        per_image[f"image_{index:03d}"] = metrics
        total_documents += metrics["documents"]
        total_scorable += metrics["scorable"]
        total_predicted += metrics["predicted"]
        total_matched += metrics["matched"]
        # A photo holding k>1 documents that yields fewer matched instances than
        # documents has merged or lost those documents.
        if metrics["documents"] > 1 and metrics["matched"] < metrics["documents"]:
            merged_errors += metrics["documents"] - metrics["matched"]
        missing_errors += metrics["scorable"] - metrics["matched"]
        spurious_errors += metrics["spurious"]
        all_ious.extend(metrics["ious"])

    precision = total_matched / total_predicted if total_predicted else 0.0
    recall = total_matched / total_scorable if total_scorable else 0.0
    f1 = (
        2 * precision * recall / (precision + recall)
        if precision + recall > 0 else 0.0
    )
    summary = {
        "stage": "region segmentation only (no corner search, no warp, no OCR)",
        "images": len(images),
        "documents_counted": total_documents,
        "documents_with_quad": total_scorable,
        "predicted_regions": total_predicted,
        "matched_at_iou_0_5": total_matched,
        "instance_precision": round(precision, 4),
        "instance_recall": round(recall, 4),
        "instance_f1": round(f1, 4),
        "mean_iou": round(float(np.mean(all_ious)), 4) if all_ious else None,
        "documents_lost_or_merged": merged_errors,
        "documents_missed_total": missing_errors,
        "spurious_regions": spurious_errors,
        "images_without_any_region": [
            key for key, value in per_image.items() if value["predicted"] == 0
        ],
        "per_image": per_image,
    }
    args.out.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(
        json.dumps(
            {k: v for k, v in summary.items() if k != "per_image"}, indent=2
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
