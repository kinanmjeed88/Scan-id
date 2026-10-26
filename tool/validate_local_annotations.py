#!/usr/bin/env python3
"""Validate local-only, human-authored Scan-id annotations without echoing them.

This tool reads only the JSON annotation exports. It never opens source images,
prints sample IDs, prints reference text, or contacts a network service.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
import unicodedata
from pathlib import Path
from typing import Any

SCHEMA = "scan-id-local-annotations-v1"
KINDS = {"unknown", "unifiedNationalId", "residenceCard", "passport", "rationCard", "other"}
VISIBILITY = {"fully_visible", "partially_occluded", "truncated", "unscorable"}
CROP_QUALITY = {"acceptable", "unacceptable", "uncertain", "not_applicable"}
REVIEW_STATUS = {"pending", "reviewed", "uncertain", "unscorable"}
ADJUDICATION_STATUS = {"not_adjudicated", "adjudicated"}
QUALITY_FLAGS = {"blur", "glare", "low_light", "perspective", "occlusion", "compression", "other"}
FORBIDDEN_KEYS = {"file", "filename", "basename", "name", "source", "source_name", "original_name", "path", "filepath", "local_path", "source_path", "original_path", "uri"}
SAMPLE_ID = re.compile(r"^[0-9a-f]{64}$")
SAFE_REVIEWER = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
SAFE_GROUP = re.compile(r"^[A-Za-z0-9_.-]{1,80}$")


class ValidationError(ValueError):
    pass


def _fail(message: str) -> None:
    raise ValidationError(message)


def _walk_for_forbidden_keys(value: Any, where: str = "root") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).lower() in FORBIDDEN_KEYS:
                _fail(f"{where} contains a forbidden source-path/name field.")
            _walk_for_forbidden_keys(child, where)
    elif isinstance(value, list):
        for child in value:
            _walk_for_forbidden_keys(child, where)


def _signed_area(points: list[tuple[float, float]]) -> float:
    return sum(
        points[i][0] * points[(i + 1) % len(points)][1]
        - points[(i + 1) % len(points)][0] * points[i][1]
        for i in range(len(points))
    ) / 2.0


def _orientation(a: tuple[float, float], b: tuple[float, float], c: tuple[float, float]) -> float:
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _segments_intersect(a: tuple[float, float], b: tuple[float, float], c: tuple[float, float], d: tuple[float, float]) -> bool:
    eps = 1e-12
    o1, o2 = _orientation(a, b, c), _orientation(a, b, d)
    o3, o4 = _orientation(c, d, a), _orientation(c, d, b)
    return (o1 * o2 < -eps) and (o3 * o4 < -eps)


def _polygon(raw: Any, where: str, *, min_points: int, max_points: int = 32) -> list[tuple[float, float]]:
    if not isinstance(raw, list) or not min_points <= len(raw) <= max_points:
        _fail(f"{where} must contain between {min_points} and {max_points} points.")
    points: list[tuple[float, float]] = []
    for index, point in enumerate(raw):
        if not isinstance(point, list) or len(point) != 2:
            _fail(f"{where} point {index + 1} must be [x, y].")
        x, y = point
        if isinstance(x, bool) or isinstance(y, bool):
            _fail(f"{where} coordinates must be numeric.")
        try:
            x, y = float(x), float(y)
        except (TypeError, ValueError):
            _fail(f"{where} coordinates must be numeric.")
        if not math.isfinite(x) or not math.isfinite(y) or not (0.0 <= x <= 1.0 and 0.0 <= y <= 1.0):
            _fail(f"{where} coordinates must be finite and normalized to [0, 1].")
        points.append((x, y))
    if len(set(points)) != len(points):
        _fail(f"{where} contains repeated vertices.")
    if abs(_signed_area(points)) <= 1e-8:
        _fail(f"{where} has zero or near-zero area.")
    n = len(points)
    for i in range(n):
        for j in range(i + 1, n):
            if j in (i, i + 1) or (i == 0 and j == n - 1):
                continue
            if _segments_intersect(points[i], points[(i + 1) % n], points[j], points[(j + 1) % n]):
                _fail(f"{where} self-intersects.")
    # Image coordinates have y increasing downward; positive signed area is clockwise.
    if _signed_area(points) < 0:
        _fail(f"{where} must be clockwise in displayed image coordinates.")
    return points


def _point_in_convex_edge(a: tuple[float, float], b: tuple[float, float], p: tuple[float, float]) -> bool:
    return _orientation(a, b, p) >= -1e-12


def _line_intersection(s: tuple[float, float], e: tuple[float, float], a: tuple[float, float], b: tuple[float, float]) -> tuple[float, float]:
    dx1, dy1 = e[0] - s[0], e[1] - s[1]
    dx2, dy2 = b[0] - a[0], b[1] - a[1]
    denom = dx1 * dy2 - dy1 * dx2
    if abs(denom) < 1e-12:
        return e
    t = ((a[0] - s[0]) * dy2 - (a[1] - s[1]) * dx2) / denom
    return (s[0] + t * dx1, s[1] + t * dy1)


def _clip_polygon(subject: list[tuple[float, float]], clip: list[tuple[float, float]]) -> list[tuple[float, float]]:
    output = subject[:]
    for i, a in enumerate(clip):
        b = clip[(i + 1) % len(clip)]
        source, output = output, []
        if not source:
            break
        start = source[-1]
        for end in source:
            start_inside = _point_in_convex_edge(a, b, start)
            end_inside = _point_in_convex_edge(a, b, end)
            if end_inside:
                if not start_inside:
                    output.append(_line_intersection(start, end, a, b))
                output.append(end)
            elif start_inside:
                output.append(_line_intersection(start, end, a, b))
            start = end
    return output


def _point_in_triangle(point: tuple[float, float], triangle: list[tuple[float, float]]) -> bool:
    return all(
        _orientation(triangle[i], triangle[(i + 1) % 3], point) >= -1e-12
        for i in range(3)
    )


def _triangulate(polygon: list[tuple[float, float]]) -> list[list[tuple[float, float]]]:
    """Ear-clip a simple clockwise-in-image polygon into non-overlapping triangles."""
    vertices = polygon[:]
    if _signed_area(vertices) < 0:
        vertices.reverse()
    triangles: list[list[tuple[float, float]]] = []
    while len(vertices) > 3:
        ear_found = False
        for i in range(len(vertices)):
            prev = vertices[(i - 1) % len(vertices)]
            current = vertices[i]
            nxt = vertices[(i + 1) % len(vertices)]
            if _orientation(prev, current, nxt) <= 1e-12:
                continue
            triangle = [prev, current, nxt]
            if any(
                _point_in_triangle(point, triangle)
                for j, point in enumerate(vertices)
                if j not in {(i - 1) % len(vertices), i, (i + 1) % len(vertices)}
            ):
                continue
            triangles.append(triangle)
            del vertices[i]
            ear_found = True
            break
        if not ear_found:
            raise ValidationError("a polygon could not be triangulated safely.")
    triangles.append(vertices[:])
    return triangles


def polygon_iou(a: list[tuple[float, float]], b: list[tuple[float, float]]) -> float:
    # Triangulate first because partial/occluded visible outlines can be concave;
    # the convex clipper then computes intersection area over non-overlapping
    # triangle pairs without requiring an external geometry package.
    inter_area = 0.0
    for triangle_a in _triangulate(a):
        for triangle_b in _triangulate(b):
            intersection = _clip_polygon(triangle_a, triangle_b)
            if len(intersection) >= 3:
                inter_area += abs(_signed_area(intersection))
    area_a, area_b = abs(_signed_area(a)), abs(_signed_area(b))
    union = area_a + area_b - inter_area
    return inter_area / union if union > 0 else 0.0


def _validate_document(doc: Any, where: str, sample_status: str) -> tuple[bool, list[tuple[float, float]] | None]:
    if not isinstance(doc, dict):
        _fail(f"{where} must be an object.")
    kind = doc.get("document_kind")
    if kind not in KINDS:
        _fail(f"{where} has an unsupported document kind.")
    visibility = doc.get("visibility")
    if visibility not in VISIBILITY:
        _fail(f"{where} has an unsupported visibility state.")
    if doc.get("crop_quality") not in CROP_QUALITY:
        _fail(f"{where} has an unsupported crop-quality label.")
    flags = doc.get("quality_flags")
    if not isinstance(flags, list) or any(flag not in QUALITY_FLAGS for flag in flags) or len(set(flags)) != len(flags):
        _fail(f"{where} has invalid quality flags.")
    reference = doc.get("ocr_reference_text", "")
    reference_verified = doc.get("ocr_reference_verified", False)
    if not isinstance(reference, str) or len(reference) > 500:
        _fail(f"{where} has an invalid OCR reference field.")
    if not isinstance(reference_verified, bool):
        _fail(f"{where} OCR reference verification flag must be boolean.")
    if bool(reference.strip()) != reference_verified:
        _fail(f"{where} OCR text must be manually checked on the image before export; clear unchecked text.")
    polygon_raw = doc.get("visible_polygon", [])
    if not isinstance(polygon_raw, list):
        _fail(f"{where} visible_polygon must be a list.")
    if visibility == "fully_visible":
        if len(polygon_raw) == 0 and sample_status in {"pending", "uncertain", "unscorable"}:
            return False, None
        points = _polygon(polygon_raw, f"{where}.visible_polygon", min_points=4, max_points=4)
        quad_raw = doc.get("quadrilateral")
        quad = _polygon(quad_raw, f"{where}.quadrilateral", min_points=4, max_points=4)
        if any(math.dist(points[i], quad[i]) > 1e-7 for i in range(4)):
            _fail(f"{where} quadrilateral must match the visible polygon point-for-point.")
        return True, points
    if visibility in {"partially_occluded", "truncated"}:
        if len(polygon_raw) < 3 and sample_status in {"pending", "uncertain", "unscorable"}:
            return False, None
        return True, _polygon(polygon_raw, f"{where}.visible_polygon", min_points=3, max_points=12)
    if polygon_raw:
        _fail(f"{where} marked unscorable must not claim a measured polygon.")
    if doc.get("quadrilateral") not in (None, []):
        _fail(f"{where} marked unscorable must not contain a quadrilateral.")
    return False, None


def load_and_validate(path: Path, *, require_complete: bool = False) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError("annotation file cannot be read as UTF-8 JSON.") from exc
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        _fail("annotation schema is missing or unsupported.")
    _walk_for_forbidden_keys(data)
    reviewer = data.get("reviewer_id")
    if not isinstance(reviewer, str) or not SAFE_REVIEWER.fullmatch(reviewer):
        _fail("reviewer_id must be a non-identifying ASCII code (1–32 letters, digits, '_' or '-').")
    samples = data.get("samples")
    if not isinstance(samples, list) or not samples:
        _fail("samples must be a non-empty list.")
    seen: set[str] = set()
    counts = {"samples": len(samples), "reviewed": 0, "pending": 0, "uncertain": 0, "unscorable": 0, "background": 0, "documents": 0, "ocr_reference_documents": 0, "groups": set(), "without_group": 0, "incomplete_documents": 0, "kind_counts": {kind: 0 for kind in sorted(KINDS)}}
    for index, sample in enumerate(samples, start=1):
        where = f"sample {index}"
        if not isinstance(sample, dict):
            _fail(f"{where} must be an object.")
        sample_id = sample.get("sample_id")
        if not isinstance(sample_id, str) or not SAMPLE_ID.fullmatch(sample_id):
            _fail(f"{where} has an invalid local content ID.")
        if sample_id in seen:
            _fail(f"{where} duplicates a sample ID.")
        seen.add(sample_id)
        status = sample.get("review_status")
        adjudication = sample.get("adjudication_status", "not_adjudicated")
        if status not in REVIEW_STATUS or adjudication not in ADJUDICATION_STATUS:
            _fail(f"{where} has an unsupported review/adjudication state.")
        counts[status] += 1
        if adjudication != "adjudicated" and require_complete:
            _fail(f"{where} is not marked adjudicated.")
        decode = sample.get("decode_status")
        width, height = sample.get("width_px"), sample.get("height_px")
        if decode not in {"ok", "failed"}:
            _fail(f"{where} has an unsupported image decode state.")
        if isinstance(width, bool) or isinstance(height, bool) or not isinstance(width, int) or not isinstance(height, int):
            _fail(f"{where} image dimensions must be integers.")
        if decode == "ok" and (width <= 0 or height <= 0):
            _fail(f"{where} decoded image dimensions must be positive.")
        if decode == "failed" and (width != 0 or height != 0 or status != "unscorable"):
            _fail(f"{where} decode failure must have zero dimensions and be marked unscorable.")
        group = sample.get("capture_group_id", "")
        if not isinstance(group, str) or (group and not SAFE_GROUP.fullmatch(group)):
            _fail(f"{where} capture group must be a non-identifying ASCII code or empty.")
        if group:
            counts["groups"].add(group)
        else:
            counts["without_group"] += 1
        background = sample.get("no_document")
        docs = sample.get("documents")
        declared_count = sample.get("document_count")
        if not isinstance(background, bool) or not isinstance(docs, list) or isinstance(declared_count, bool) or not isinstance(declared_count, int):
            _fail(f"{where} has invalid background/document-count fields.")
        if background and (docs or declared_count != 0):
            _fail(f"{where} marked as background must have zero documents.")
        if not background and declared_count != len(docs):
            _fail(f"{where} document_count does not match its annotation list.")
        if background:
            counts["background"] += 1
        counts["documents"] += len(docs)
        if require_complete and status not in {"reviewed", "unscorable"}:
            _fail(f"{where} is pending or uncertain; adjudicate it before splitting.")
        for doc_index, doc in enumerate(docs, start=1):
            complete, _ = _validate_document(doc, f"{where}, document {doc_index}", status)
            if doc.get("ocr_reference_text", "").strip():
                counts["ocr_reference_documents"] += 1
            if not complete:
                counts["incomplete_documents"] += 1
                if require_complete and status == "reviewed":
                    _fail(f"{where}, document {doc_index} has no complete measured outline.")
            if doc.get("document_kind"):
                counts["kind_counts"][doc["document_kind"]] += 1
    if require_complete:
        if counts["without_group"]:
            _fail("every sample needs a capture group before split creation.")
        if counts["incomplete_documents"]:
            _fail("reviewed documents must have a valid visible outline before split creation.")
    counts["groups"] = len(counts["groups"])
    counts["reviewer_id"] = reviewer
    return data, counts


def _max_iou_pairs(a: list[tuple[float, float]] | None, b: list[tuple[float, float]] | None) -> list[tuple[int, int, float]]:
    if not a or not b:
        return []
    if len(a) > 8 or len(b) > 8:
        candidates = sorted(((polygon_iou(x[1], y[1]), i, j) for i, x in enumerate(a) if x[1] for j, y in enumerate(b) if y[1]), reverse=True)
        used_a: set[int] = set(); used_b: set[int] = set(); result=[]
        for score, i, j in candidates:
            if i not in used_a and j not in used_b:
                used_a.add(i); used_b.add(j); result.append((i,j,score))
        return result
    best_score=-1.0; best: list[tuple[int,int,float]]=[]
    def search(i: int, used: set[int], pairs: list[tuple[int,int,float]], score: float) -> None:
        nonlocal best_score,best
        if i==len(a):
            if score>best_score: best_score=score;best=pairs[:]
            return
        search(i+1,used,pairs,score)
        if a[i][1] is None:return
        for j,item in enumerate(b):
            if j in used or item[1] is None:continue
            value=polygon_iou(a[i][1],item[1])
            used.add(j);pairs.append((i,j,value));search(i+1,used,pairs,score+value);pairs.pop();used.remove(j)
    search(0,set(),[],0.0)
    return best


def compare(left: dict[str, Any], right: dict[str, Any], polygon_iou_threshold: float) -> dict[str, Any]:
    if left.get("reviewer_id") == right.get("reviewer_id"):
        _fail("the two independent review files must have different reviewer IDs.")
    if not math.isfinite(polygon_iou_threshold) or not 0.0 <= polygon_iou_threshold <= 1.0:
        _fail("the pre-registered polygon IoU review threshold must be between 0 and 1.")

    amap = {sample["sample_id"]: sample for sample in left["samples"]}
    bmap = {sample["sample_id"]: sample for sample in right["samples"]}
    common = set(amap) & set(bmap)
    result = {
        "common_samples": len(common),
        "missing_from_second": len(set(amap) - set(bmap)),
        "missing_from_first": len(set(bmap) - set(amap)),
        "capture_group_disagreements": 0,
        "review_status_disagreements": 0,
        "adjudication_status_disagreements": 0,
        "decode_status_disagreements": 0,
        "dimension_disagreements": 0,
        "document_count_disagreements": 0,
        "background_disagreements": 0,
        "kind_disagreements": 0,
        "visibility_disagreements": 0,
        "crop_quality_disagreements": 0,
        "quality_flag_disagreements": 0,
        "boundary_availability_disagreements": 0,
        "unmatched_outline_documents": 0,
        "ocr_reference_coverage_disagreements": 0,
        "ocr_reference_text_disagreements": 0,
        "polygon_iou_below_threshold": 0,
        "polygon_iou_review_threshold": polygon_iou_threshold,
        "matched_documents": 0,
        "mean_polygon_iou": None,
    }
    ious: list[float] = []
    for sample_id in common:
        a, b = amap[sample_id], bmap[sample_id]
        for key, metric in (
            ("capture_group_id", "capture_group_disagreements"),
            ("review_status", "review_status_disagreements"),
            ("adjudication_status", "adjudication_status_disagreements"),
            ("decode_status", "decode_status_disagreements"),
        ):
            if a.get(key) != b.get(key):
                result[metric] += 1
        if (a.get("width_px"), a.get("height_px")) != (b.get("width_px"), b.get("height_px")):
            result["dimension_disagreements"] += 1
        if len(a["documents"]) != len(b["documents"]):
            result["document_count_disagreements"] += 1
        if a["no_document"] != b["no_document"]:
            result["background_disagreements"] += 1

        def prepared(sample: dict[str, Any]) -> list[tuple[dict[str, Any], list[tuple[float, float]] | None]]:
            return [
                (
                    document,
                    _polygon(document["visible_polygon"], "review polygon", min_points=3)
                    if document.get("visible_polygon")
                    else None,
                )
                for document in sample["documents"]
            ]

        ap, bp = prepared(a), prepared(b)
        available_a = sum(polygon is not None for _, polygon in ap)
        available_b = sum(polygon is not None for _, polygon in bp)
        if available_a != available_b:
            result["boundary_availability_disagreements"] += 1
        pairs = _max_iou_pairs(ap, bp)
        matched_a = {i for i, _, _ in pairs}
        matched_b = {j for _, j, _ in pairs}
        result["matched_documents"] += len(pairs)
        result["unmatched_outline_documents"] += (
            available_a - sum(ap[i][1] is not None for i in matched_a)
            + available_b - sum(bp[j][1] is not None for j in matched_b)
        )
        for i, j, value in pairs:
            da, db = ap[i][0], bp[j][0]
            if da["document_kind"] != db["document_kind"]:
                result["kind_disagreements"] += 1
            if da["visibility"] != db["visibility"]:
                result["visibility_disagreements"] += 1
            if da["crop_quality"] != db["crop_quality"]:
                result["crop_quality_disagreements"] += 1
            if set(da["quality_flags"]) != set(db["quality_flags"]):
                result["quality_flag_disagreements"] += 1
            ref_a = unicodedata.normalize("NFC", da.get("ocr_reference_text", ""))
            ref_b = unicodedata.normalize("NFC", db.get("ocr_reference_text", ""))
            if bool(ref_a.strip()) != bool(ref_b.strip()):
                result["ocr_reference_coverage_disagreements"] += 1
            elif ref_a.strip() and " ".join(ref_a.split()) != " ".join(ref_b.split()):
                result["ocr_reference_text_disagreements"] += 1
            if value < polygon_iou_threshold:
                result["polygon_iou_below_threshold"] += 1
            ious.append(value)
    if ious:
        result["mean_polygon_iou"] = sum(ious) / len(ious)
    result["reviewer_ids_differ"] = True
    return result


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("annotations",type=Path,help="local JSON export from one reviewer")
    parser.add_argument("--compare",type=Path,help="optional second independent reviewer JSON")
    parser.add_argument("--require-complete",action="store_true",help="fail for pending/uncertain samples, missing groups, or incomplete outlines")
    parser.add_argument("--polygon-iou-review-threshold",type=float,help="pre-registered inter-reviewer boundary agreement threshold; required with --compare")
    args=parser.parse_args()
    if args.compare and args.polygon_iou_review_threshold is None:
        parser.error("--compare requires a polygon IoU review threshold fixed before inspecting reviewer results")
    if args.polygon_iou_review_threshold is not None and not 0.0 <= args.polygon_iou_review_threshold <= 1.0:
        parser.error("polygon IoU review threshold must be between 0 and 1")
    try:
        data,counts=load_and_validate(args.annotations,require_complete=args.require_complete)
        print(f"PASS: schema and geometry valid for {counts['samples']} sample(s); reviewer code accepted (redacted).")
        print(f"Summary: reviewed={counts['reviewed']}, pending={counts['pending']}, uncertain={counts['uncertain']}, unscorable={counts['unscorable']}, background={counts['background']}, documents={counts['documents']}, capture_groups={counts['groups']}, missing_group={counts['without_group']}, incomplete_outlines={counts['incomplete_documents']}.")
        print("Document-kind counts: "+", ".join(f"{kind}={count}" for kind,count in counts["kind_counts"].items()))
        print(f"Manually verified OCR-reference documents: {counts['ocr_reference_documents']} (reference text is never echoed).")
        if args.compare:
            other,other_counts=load_and_validate(args.compare,require_complete=args.require_complete)
            metrics=compare(data,other,args.polygon_iou_review_threshold)
            print(f"Second reviewer code accepted (redacted); samples={other_counts['samples']}; reviewed={other_counts['reviewed']}; uncertain={other_counts['uncertain']}.")
            print("Blind agreement summary (no sample IDs or text): "+json.dumps(metrics,sort_keys=True))
            disagreement_metrics = (
                "missing_from_second",
                "missing_from_first",
                "capture_group_disagreements",
                "review_status_disagreements",
                "adjudication_status_disagreements",
                "decode_status_disagreements",
                "dimension_disagreements",
                "document_count_disagreements",
                "background_disagreements",
                "kind_disagreements",
                "visibility_disagreements",
                "crop_quality_disagreements",
                "quality_flag_disagreements",
                "boundary_availability_disagreements",
                "unmatched_outline_documents",
                "ocr_reference_coverage_disagreements",
                "ocr_reference_text_disagreements",
                "polygon_iou_below_threshold",
            )
            disagreements = sum(metrics[key] for key in disagreement_metrics)
            if disagreements:
                print(f"REVIEW REQUIRED: {disagreements} aggregate disagreement(s); adjudicate before any accuracy calculation.",file=sys.stderr)
                return 2
        if not args.require_complete and (counts["pending"] or counts["uncertain"] or counts["incomplete_documents"]):
            print("NOTICE: this is an incomplete draft; do not use it for model tuning or accuracy claims.")
        return 0
    except ValidationError as exc:
        print(f"FAIL: local annotation validation: {exc}",file=sys.stderr)
        return 1


if __name__=="__main__":
    raise SystemExit(main())
