#!/usr/bin/env python3
"""Validate local-only, human-authored Scan-id reference annotations (v2).

Enforces schema version 2.0.0 invariants, privacy/no-PII rules, EXIF-aware
normalized coordinate geometry, canonical clockwise corner ordering
(TL -> TR -> BR -> BL), duplicate/near-vertex detection, separation between
machine suggestions and human-verified annotations, optional on-disk image
existence/decode verification, lossless save/reload, and blind two-reviewer
agreement analysis without echoing sample IDs, filenames, or personal text.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]

SCHEMA = "scan-id-local-annotations-v2"
LEGACY_SCHEMA_V1 = "scan-id-local-annotations-v1"
SCHEMA_VERSION_RE = re.compile(r"^2\.[0-9]+\.[0-9]+$")
COORDINATE_SYSTEM = "normalized_xy_after_exif_orientation_clockwise_from_display_top_left"

KINDS = {"unknown", "unifiedNationalId", "residenceCard", "passport", "rationCard", "other"}
BOUNDARY_STATUS = {"complete", "occluded", "partial", "undeterminable"}
CROP_QUALITY = {"acceptable", "unacceptable", "uncertain", "not_applicable"}
IMAGE_FORMATS = {"jpeg", "png", "webp", "bmp", "unknown"}
DECODE_STATUS = {"ok", "failed"}
IMAGE_SOURCES = {
    "camera_photo",
    "screenshot",
    "collage",
    "video_frame",
    "flatbed_or_web_scan",
    "synthetic_graphic",
    "unknown",
}
SUITABILITY_STATUS = {"annotatable", "unreadable", "unclear", "needs_review"}
ANNOTATION_STATUS = {"unannotated", "in_progress", "annotated", "second_review", "excluded"}
EXCLUSION_REASONS = {
    "",
    "decode_failed",
    "exact_or_near_duplicate",
    "video_or_ui_recording",
    "backup_container",
    "synthetic_or_promotional_mockup",
    "pre_cropped_no_background",
    "unreadable_or_extreme_blur",
    "boundary_unscorable",
    "unresolved_annotator_dispute",
}
IMAGE_QUALITY_LEVELS = {"good", "medium", "poor", "unusable", "unassessed"}
DIFFICULTY_FLAGS = {
    "occlusion",
    "partial_truncation",
    "glare",
    "blur",
    "severe_perspective",
    "document_overlap",
    "low_light",
    "compression",
    "laminated_outer_pouch",
    "other",
}
HUMAN_LABEL_ORIGINS = {"human_manual", "human_verified_from_suggestion"}
AI_PROPOSAL_SOURCES = {"frozen_ai_hybrid", "classical_only", "external_detector"}
AI_GATE_VERDICTS = {"accepted", "needsReview", "rejected", "unknown"}

SECOND_REVIEW_STATUS = {
    "not_started",
    "agreed",
    "disputed",
    "resolved",
    "excluded_after_dispute",
}
DISPUTE_STATUS = {"none", "open_dispute", "resolved_by_protocol", "excluded_unresolvable"}
RESOLUTION_CODES = {
    "",
    "unanimous_primary_and_secondary",
    "adjudicated_visible_boundary",
    "adjudicated_kind_to_unknown",
    "adjudicated_boundary_undeterminable",
    "excluded_due_to_ambiguity",
}

FORBIDDEN_KEYS = {
    "file",
    "filename",
    "basename",
    "name",
    "full_name",
    "person_name",
    "holder_name",
    "id_number",
    "national_id",
    "passport_number",
    "ration_number",
    "address",
    "birth_date",
    "dob",
    "ocr_text",
    "ocr_reference_text",
    "transcript",
    "source_name",
    "original_name",
    "path",
    "filepath",
    "local_path",
    "source_path",
    "original_path",
    "uri",
}

IMAGE_ID_RE = re.compile(r"^[0-9a-f]{64}$")
DHASH64_RE = re.compile(r"^[0-9a-f]{16}$")
INTERNAL_CODE_RE = re.compile(r"^[A-Z]{2,8}-[0-9]{2,5}$")
SAFE_REVIEWER_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
SAFE_GROUP_RE = re.compile(r"^[A-Za-z0-9_.-]{1,80}$")
SAFE_CLUSTER_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
SAFE_DOC_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{3,80}$")

MIN_POLYGON_AREA = 1e-4
MIN_VERTEX_DISTANCE = 0.005
MIN_VERTEX_PIXEL_DISTANCE = 2.0
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


class ValidationError(ValueError):
    pass


def _fail(message: str) -> None:
    raise ValidationError(message)


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_num(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(float(value))


def _walk_for_forbidden_keys(value: Any, where: str = "root") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).lower() in FORBIDDEN_KEYS:
                _fail(f"{where} contains a forbidden PII/source-path/text field ({key!r}).")
            _walk_for_forbidden_keys(child, where)
    elif isinstance(value, list):
        for child in value:
            _walk_for_forbidden_keys(child, where)


# ---------------------------------------------------------------------------
# EXIF & Display Coordinate Bijections
# ---------------------------------------------------------------------------


def expected_oriented_dimensions(raw_width: int, raw_height: int, exif_orientation: int) -> tuple[int, int]:
    """Return (width_px, height_px) after applying EXIF orientation (tag 274)."""
    if exif_orientation in {5, 6, 7, 8}:
        return raw_height, raw_width
    return raw_width, raw_height


def raw_to_oriented_normalized(x_raw: float, y_raw: float, exif_orientation: int) -> tuple[float, float]:
    """Map normalized [0, 1] raw buffer coords to EXIF-oriented display coords."""
    if not (_is_num(x_raw) and _is_num(y_raw) and 0.0 <= x_raw <= 1.0 and 0.0 <= y_raw <= 1.0):
        _fail("raw normalized coordinates must be finite and within [0, 1].")
    if exif_orientation in {0, 1}:
        return float(x_raw), float(y_raw)
    if exif_orientation == 2:  # mirror horizontal
        return 1.0 - float(x_raw), float(y_raw)
    if exif_orientation == 3:  # rotate 180
        return 1.0 - float(x_raw), 1.0 - float(y_raw)
    if exif_orientation == 4:  # mirror vertical
        return float(x_raw), 1.0 - float(y_raw)
    if exif_orientation == 5:  # transpose (mirror horizontal + rotate 270 CW)
        return float(y_raw), float(x_raw)
    if exif_orientation == 6:  # rotate 90 CW
        return 1.0 - float(y_raw), float(x_raw)
    if exif_orientation == 7:  # transverse
        return 1.0 - float(y_raw), 1.0 - float(x_raw)
    if exif_orientation == 8:  # rotate 270 CW
        return float(y_raw), 1.0 - float(x_raw)
    _fail("exif_orientation must be an integer between 0 and 8.")


def oriented_to_raw_normalized(x_ord: float, y_ord: float, exif_orientation: int) -> tuple[float, float]:
    """Inverse of raw_to_oriented_normalized for all EXIF orientations 0..8."""
    if not (_is_num(x_ord) and _is_num(y_ord) and 0.0 <= x_ord <= 1.0 and 0.0 <= y_ord <= 1.0):
        _fail("oriented normalized coordinates must be finite and within [0, 1].")
    if exif_orientation in {0, 1}:
        return float(x_ord), float(y_ord)
    if exif_orientation == 2:
        return 1.0 - float(x_ord), float(y_ord)
    if exif_orientation == 3:
        return 1.0 - float(x_ord), 1.0 - float(y_ord)
    if exif_orientation == 4:
        return float(x_ord), 1.0 - float(y_ord)
    if exif_orientation == 5:
        return float(y_ord), float(x_ord)
    if exif_orientation == 6:
        return float(y_ord), 1.0 - float(x_ord)
    if exif_orientation == 7:
        return 1.0 - float(y_ord), 1.0 - float(x_ord)
    if exif_orientation == 8:
        return 1.0 - float(y_ord), float(x_ord)
    _fail("exif_orientation must be an integer between 0 and 8.")


def display_click_to_normalized(
    view_x: float,
    view_y: float,
    *,
    pan_x: float,
    pan_y: float,
    zoom: float,
    canvas_width: float,
    canvas_height: float,
) -> tuple[float, float]:
    """Convert zoomed/panned viewport coordinates into clamped [0, 1] image coords."""
    if zoom <= 0 or canvas_width <= 0 or canvas_height <= 0:
        _fail("zoom and canvas dimensions must be positive.")
    cx = (view_x - pan_x) / zoom
    cy = (view_y - pan_y) / zoom
    nx = min(1.0, max(0.0, cx / canvas_width))
    ny = min(1.0, max(0.0, cy / canvas_height))
    return round(nx, 6), round(ny, 6)


# ---------------------------------------------------------------------------
# Polygon & Canonical 4-Corner Geometry
# ---------------------------------------------------------------------------


def _signed_area(points: list[tuple[float, float]]) -> float:
    return (
        sum(
            points[i][0] * points[(i + 1) % len(points)][1]
            - points[(i + 1) % len(points)][0] * points[i][1]
            for i in range(len(points))
        )
        / 2.0
    )


def _orientation(a: tuple[float, float], b: tuple[float, float], c: tuple[float, float]) -> float:
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _on_segment(a: tuple[float, float], b: tuple[float, float], p: tuple[float, float], eps: float = 1e-9) -> bool:
    return (
        min(a[0], b[0]) - eps <= p[0] <= max(a[0], b[0]) + eps
        and min(a[1], b[1]) - eps <= p[1] <= max(a[1], b[1]) + eps
    )


def _segments_intersect_or_touch(
    a: tuple[float, float],
    b: tuple[float, float],
    c: tuple[float, float],
    d: tuple[float, float],
) -> bool:
    eps = 1e-11
    o1 = _orientation(a, b, c)
    o2 = _orientation(a, b, d)
    o3 = _orientation(c, d, a)
    o4 = _orientation(c, d, b)
    if (o1 * o2 < -eps) and (o3 * o4 < -eps):
        return True
    if abs(o1) <= eps and _on_segment(a, b, c):
        return True
    if abs(o2) <= eps and _on_segment(a, b, d):
        return True
    if abs(o3) <= eps and _on_segment(c, d, a):
        return True
    if abs(o4) <= eps and _on_segment(c, d, b):
        return True
    return False


def canonicalize_quad_clockwise_tl(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Order 4 vertices clockwise in y-down image coords starting at display TL."""
    if len(points) != 4:
        _fail("canonicalize_quad_clockwise_tl requires exactly 4 vertices.")
    cx = sum(p[0] for p in points) / 4.0
    cy = sum(p[1] for p in points) / 4.0
    ordered = sorted(points, key=lambda p: math.atan2(p[1] - cy, p[0] - cx))
    if _signed_area(ordered) < 0:
        ordered.reverse()
    start = min(range(4), key=lambda idx: (round(ordered[idx][0] + ordered[idx][1], 9), round(ordered[idx][1], 9)))
    return ordered[start:] + ordered[:start]


def _validate_polygon(
    raw: Any,
    where: str,
    *,
    min_points: int,
    max_points: int = 12,
    width_px: int = 0,
    height_px: int = 0,
    require_convex_canonical_quad: bool = False,
) -> list[tuple[float, float]]:
    if not isinstance(raw, list) or not (min_points <= len(raw) <= max_points):
        _fail(f"{where} must contain between {min_points} and {max_points} points.")
    points: list[tuple[float, float]] = []
    for index, point in enumerate(raw, start=1):
        if not isinstance(point, list) or len(point) != 2:
            _fail(f"{where} point {index} must be [x, y].")
        x_raw, y_raw = point
        if not (_is_num(x_raw) and _is_num(y_raw)):
            _fail(f"{where} coordinates must be finite numbers.")
        x, y = float(x_raw), float(y_raw)
        if not (0.0 <= x <= 1.0 and 0.0 <= y <= 1.0):
            _fail(f"{where} coordinates must be normalized within [0, 1].")
        points.append((x, y))

    if len(set(points)) != len(points):
        _fail(f"{where} contains duplicate vertices.")

    n = len(points)
    for i in range(n):
        for j in range(i + 1, n):
            if math.dist(points[i], points[j]) < MIN_VERTEX_DISTANCE:
                _fail(f"{where} contains vertices that are too close together (< {MIN_VERTEX_DISTANCE}).")
            if width_px > 0 and height_px > 0:
                px_dist = math.hypot(
                    (points[i][0] - points[j][0]) * width_px,
                    (points[i][1] - points[j][1]) * height_px,
                )
                if px_dist < MIN_VERTEX_PIXEL_DISTANCE:
                    _fail(f"{where} contains vertices closer than {MIN_VERTEX_PIXEL_DISTANCE}px.")

    for i in range(n):
        for j in range(i + 1, n):
            if j in (i, i + 1) or (i == 0 and j == n - 1):
                continue
            if _segments_intersect_or_touch(
                points[i], points[(i + 1) % n], points[j], points[(j + 1) % n]
            ):
                _fail(f"{where} self-intersects.")

    area = _signed_area(points)
    if abs(area) < MIN_POLYGON_AREA:
        _fail(f"{where} has zero or near-zero area (< {MIN_POLYGON_AREA}).")
    if area < 0:
        _fail(f"{where} must be ordered clockwise in displayed image coordinates.")

    if require_convex_canonical_quad:
        if n != 4:
            _fail(f"{where} must have 4 corners.")
        for i in range(4):
            a = points[i]
            b = points[(i + 1) % 4]
            c = points[(i + 2) % 4]
            cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
            if cross <= 1e-6:
                _fail(f"{where} must be a strictly convex clockwise quadrilateral.")
        start = min(range(4), key=lambda idx: (round(points[idx][0] + points[idx][1], 6), round(points[idx][1], 6)))
        if start != 0:
            sums = [points[idx][0] + points[idx][1] for idx in range(4)]
            if sums[0] - sums[start] > 1e-4:
                _fail(
                    f"{where} corner order must start at top-left (TL -> TR -> BR -> BL); "
                    f"expected vertex {start + 1} first."
                )

    return points


def _point_in_convex_edge(a: tuple[float, float], b: tuple[float, float], p: tuple[float, float]) -> bool:
    return _orientation(a, b, p) >= -1e-12


def _line_intersection(
    s: tuple[float, float],
    e: tuple[float, float],
    a: tuple[float, float],
    b: tuple[float, float],
) -> tuple[float, float]:
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
    return all(_orientation(triangle[i], triangle[(i + 1) % 3], point) >= -1e-12 for i in range(3))


def _triangulate(polygon: list[tuple[float, float]]) -> list[list[tuple[float, float]]]:
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
    inter_area = 0.0
    for triangle_a in _triangulate(a):
        for triangle_b in _triangulate(b):
            intersection = _clip_polygon(triangle_a, triangle_b)
            if len(intersection) >= 3:
                inter_area += abs(_signed_area(intersection))
    area_a, area_b = abs(_signed_area(a)), abs(_signed_area(b))
    union = area_a + area_b - inter_area
    return inter_area / union if union > 0 else 0.0


def compute_dhash64_hex(pil_image: Any) -> str:
    """Compute 64-bit horizontal gradient dHash (16 lowercase hex chars) after EXIF transpose."""
    from PIL import Image, ImageOps

    oriented = ImageOps.exif_transpose(pil_image).convert("L").resize((9, 8), Image.Resampling.BILINEAR)
    pixels = list(oriented.getdata())
    bits = 0
    for row in range(8):
        offset = row * 9
        for col in range(8):
            bits = (bits << 1) | (1 if pixels[offset + col + 1] > pixels[offset + col] else 0)
    return f"{bits:016x}"


def dhash64_hamming(left_hex: str, right_hex: str) -> int:
    if not (DHASH64_RE.fullmatch(left_hex) and DHASH64_RE.fullmatch(right_hex)):
        _fail("dHash64 values must be 16 lowercase hex characters.")
    return (int(left_hex, 16) ^ int(right_hex, 16)).bit_count()


# ---------------------------------------------------------------------------
# Document, AI Suggestion & Sample Validation
# ---------------------------------------------------------------------------


def _validate_ai_suggestion(
    raw: Any,
    where: str,
    seen_suggestion_ids: set[str],
    width_px: int,
    height_px: int,
) -> None:
    if not isinstance(raw, dict):
        _fail(f"{where} must be an object.")
    suggestion_id = raw.get("suggestion_id")
    if not isinstance(suggestion_id, str) or not SAFE_DOC_ID_RE.fullmatch(suggestion_id):
        _fail(f"{where} has an invalid suggestion_id.")
    if suggestion_id in seen_suggestion_ids:
        _fail(f"{where} duplicates a suggestion_id.")
    seen_suggestion_ids.add(suggestion_id)

    source = raw.get("proposal_source")
    if source not in AI_PROPOSAL_SOURCES:
        _fail(f"{where} has an unsupported proposal_source.")
    conf = raw.get("confidence")
    if not _is_num(conf) or not (0.0 <= float(conf) <= 1.0):
        _fail(f"{where} confidence must be in [0, 1].")
    if raw.get("gate_verdict") not in AI_GATE_VERDICTS:
        _fail(f"{where} has an unsupported gate_verdict.")
    corners_raw = raw.get("corners")
    if corners_raw is not None:
        _validate_polygon(
            corners_raw,
            f"{where}.corners",
            min_points=4,
            max_points=4,
            width_px=width_px,
            height_px=height_px,
            require_convex_canonical_quad=False,
        )
    bbox = raw.get("region_bbox")
    if bbox is not None:
        if not isinstance(bbox, list) or len(bbox) != 4 or not all(_is_num(v) and 0.0 <= float(v) <= 1.0 for v in bbox):
            _fail(f"{where}.region_bbox must be [left, top, right, bottom] in [0, 1].")
        if float(bbox[2]) <= float(bbox[0]) or float(bbox[3]) <= float(bbox[1]):
            _fail(f"{where}.region_bbox must have positive width and height.")


def _validate_document(
    doc: Any,
    where: str,
    *,
    annotation_status: str,
    width_px: int,
    height_px: int,
    seen_doc_ids: set[str],
) -> tuple[bool, bool, list[tuple[float, float]] | None, list[tuple[float, float]] | None]:
    """Return (outline_complete, four_corner_complete, visible_poly, corners_quad)."""
    if not isinstance(doc, dict):
        _fail(f"{where} must be an object.")
    doc_id = doc.get("document_id")
    if not isinstance(doc_id, str) or not SAFE_DOC_ID_RE.fullmatch(doc_id):
        _fail(f"{where} has an invalid document_id.")
    if doc_id in seen_doc_ids:
        _fail(f"{where} duplicates a document_id.")
    seen_doc_ids.add(doc_id)

    origin = doc.get("label_origin")
    if origin not in HUMAN_LABEL_ORIGINS:
        _fail(
            f"{where} has invalid label_origin; machine suggestions or legacy crops "
            "must never be stored as human annotations."
        )
    human_verified = doc.get("human_verified")
    if not isinstance(human_verified, bool):
        _fail(f"{where} human_verified must be boolean.")
    if annotation_status in {"annotated", "second_review"} and not human_verified:
        _fail(f"{where} in an annotated/reviewed sample must have human_verified=true.")

    kind = doc.get("document_kind")
    if kind not in KINDS:
        _fail(f"{where} has an unsupported document_kind.")
    b_status = doc.get("boundary_status")
    if b_status not in BOUNDARY_STATUS:
        _fail(f"{where} has an unsupported boundary_status.")
    if doc.get("crop_quality") not in CROP_QUALITY:
        _fail(f"{where} has an unsupported crop_quality.")

    flags = doc.get("quality_flags")
    if (
        not isinstance(flags, list)
        or any(flag not in DIFFICULTY_FLAGS for flag in flags)
        or len(set(flags)) != len(flags)
    ):
        _fail(f"{where} has invalid or duplicate quality_flags.")

    corners_raw = doc.get("corners")
    poly_raw = doc.get("visible_polygon")
    if not isinstance(poly_raw, list):
        _fail(f"{where}.visible_polygon must be a list.")

    is_final_human = annotation_status in {"annotated", "second_review"}

    if b_status == "undeterminable":
        if corners_raw is not None:
            _fail(f"{where} marked undeterminable must have corners=null.")
        if poly_raw:
            _fail(f"{where} marked undeterminable must have an empty visible_polygon.")
        return False, False, None, None

    if b_status == "complete":
        if not is_final_human and corners_raw is None and len(poly_raw) == 0:
            return False, False, None, None
        if corners_raw is None:
            _fail(f"{where} marked complete must provide 4 corners.")
        corners = _validate_polygon(
            corners_raw,
            f"{where}.corners",
            min_points=4,
            max_points=4,
            width_px=width_px,
            height_px=height_px,
            require_convex_canonical_quad=True,
        )
        poly = _validate_polygon(
            poly_raw,
            f"{where}.visible_polygon",
            min_points=4,
            max_points=4,
            width_px=width_px,
            height_px=height_px,
            require_convex_canonical_quad=True,
        )
        if any(math.dist(corners[i], poly[i]) > 1e-7 for i in range(4)):
            _fail(f"{where}.visible_polygon must match corners point-for-point when complete.")
        return True, True, poly, corners

    # b_status in {"occluded", "partial"}
    if not is_final_human and len(poly_raw) < 3 and corners_raw is None:
        return False, False, None, None
    poly = _validate_polygon(
        poly_raw,
        f"{where}.visible_polygon",
        min_points=3,
        max_points=12,
        width_px=width_px,
        height_px=height_px,
        require_convex_canonical_quad=False,
    )
    corners: list[tuple[float, float]] | None = None
    if corners_raw is not None:
        corners = _validate_polygon(
            corners_raw,
            f"{where}.corners",
            min_points=4,
            max_points=4,
            width_px=width_px,
            height_px=height_px,
            require_convex_canonical_quad=True,
        )
    return True, corners is not None, poly, corners


def _validate_second_review(
    sr: Any,
    where: str,
    *,
    annotation_status: str,
    primary_annotator: str,
) -> dict[str, str]:
    if not isinstance(sr, dict):
        _fail(f"{where}.second_review must be an object.")
    status = sr.get("status")
    reviewer = sr.get("reviewer_id", "")
    reviewed_at = sr.get("reviewed_at", "")
    dispute = sr.get("dispute_status", "none")
    adjudicator = sr.get("adjudicator_id", "")
    adjudicated_at = sr.get("adjudicated_at", "")
    resolution = sr.get("resolution_code", "")

    if status not in SECOND_REVIEW_STATUS:
        _fail(f"{where}.second_review.status is invalid.")
    if dispute not in DISPUTE_STATUS:
        _fail(f"{where}.second_review.dispute_status is invalid.")
    if resolution not in RESOLUTION_CODES:
        _fail(f"{where}.second_review.resolution_code is invalid.")
    for field_name, val in (("reviewer_id", reviewer), ("adjudicator_id", adjudicator)):
        if not isinstance(val, str) or (val and not SAFE_REVIEWER_RE.fullmatch(val)):
            _fail(f"{where}.second_review.{field_name} must be empty or a non-identifying ASCII code.")
    for field_name, val in (("reviewed_at", reviewed_at), ("adjudicated_at", adjudicated_at)):
        if not isinstance(val, str) or len(val) > 40:
            _fail(f"{where}.second_review.{field_name} must be an ISO timestamp string or empty.")

    if status == "not_started":
        if annotation_status == "second_review":
            _fail(f"{where} has annotation_status='second_review' while second_review.status='not_started'.")
        if dispute != "none" or resolution != "":
            _fail(f"{where} with second_review.status='not_started' cannot claim dispute/resolution fields.")
    else:
        if not reviewer or not reviewed_at:
            _fail(f"{where}.second_review requires reviewer_id and reviewed_at once started.")
        if primary_annotator and reviewer == primary_annotator:
            _fail(f"{where}.second_review.reviewer_id must differ from the primary annotator_id.")

    if status == "disputed" and dispute != "open_dispute":
        _fail(f"{where}.second_review with status='disputed' must have dispute_status='open_dispute'.")
    if status == "resolved":
        if dispute != "resolved_by_protocol" or not adjudicator or not adjudicated_at or not resolution:
            _fail(
                f"{where}.second_review with status='resolved' requires adjudicator_id, "
                "adjudicated_at, dispute_status='resolved_by_protocol', and resolution_code."
            )
    if status == "excluded_after_dispute":
        if annotation_status != "excluded":
            _fail(f"{where} marked excluded_after_dispute must have annotation_status='excluded'.")
        if dispute != "excluded_unresolvable":
            _fail(f"{where} marked excluded_after_dispute must have dispute_status='excluded_unresolvable'.")

    return {
        "status": status,
        "reviewer_id": reviewer,
        "reviewed_at": reviewed_at,
        "dispute_status": dispute,
        "adjudicator_id": adjudicator,
        "adjudicated_at": adjudicated_at,
        "resolution_code": resolution,
    }


def verify_referenced_images(data: dict[str, Any], images_dir: Path) -> dict[str, int]:
    """Verify every referenced image_id exists in images_dir and decodes as declared."""
    if not images_dir.is_dir():
        _fail("referenced images directory does not exist or is not a directory.")
    from PIL import Image, ImageOps

    disk_by_sha: dict[str, Path] = {}
    for candidate in sorted(images_dir.rglob("*")):
        if not candidate.is_file() or candidate.suffix.lower() not in IMAGE_SUFFIXES:
            continue
        digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
        disk_by_sha.setdefault(digest, candidate)

    verified_ok = 0
    verified_failed = 0
    for idx, sample in enumerate(data["samples"], start=1):
        where = f"sample {idx}"
        image_id = sample["image_id"]
        disk_path = disk_by_sha.get(image_id)
        if disk_path is None:
            _fail(f"{where} referenced image_id was not found in the local images directory.")
        declared_decode = sample["decode_status"]
        try:
            with Image.open(disk_path) as img:
                img.load()
                raw_w, raw_h = img.size
                exif = img.getexif()
                exif_orient = int(exif.get(274, 1)) if exif else 1
                if exif_orient not in range(0, 9):
                    exif_orient = 1
                oriented = ImageOps.exif_transpose(img)
                ord_w, ord_h = oriented.size
                actual_dhash = compute_dhash64_hex(img)
        except Exception:
            if declared_decode != "failed":
                _fail(f"{where} is marked decode_status='ok' but failed image decoding on disk.")
            verified_failed += 1
            continue

        if declared_decode == "failed":
            _fail(f"{where} is marked decode_status='failed' but decoded cleanly on disk.")
        if (sample["raw_width_px"], sample["raw_height_px"]) != (raw_w, raw_h):
            _fail(f"{where} raw dimensions do not match the decoded image on disk.")
        if (sample["width_px"], sample["height_px"]) != (ord_w, ord_h):
            _fail(f"{where} EXIF-oriented dimensions do not match the decoded image on disk.")
        if sample["exif_orientation"] != exif_orient:
            _fail(f"{where} exif_orientation does not match the image EXIF header on disk.")
        declared_dhash = sample.get("perceptual_dhash64", "")
        if declared_dhash and dhash64_hamming(declared_dhash, actual_dhash) > 4:
            _fail(f"{where} perceptual_dhash64 does not match the decoded image on disk.")
        verified_ok += 1

    return {
        "disk_images_indexed": len(disk_by_sha),
        "verified_decoded_ok": verified_ok,
        "verified_decode_failed": verified_failed,
    }


def validate_payload(
    data: Any,
    *,
    require_complete: bool = False,
    images_dir: Path | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    if not isinstance(data, dict):
        _fail("annotation root must be a JSON object.")
    if data.get("schema") != SCHEMA:
        _fail(f"annotation schema must be {SCHEMA!r}.")
    version = data.get("schema_version")
    if not isinstance(version, str) or not SCHEMA_VERSION_RE.fullmatch(version):
        _fail("schema_version must follow '2.x.y'.")
    if data.get("coordinate_system") != COORDINATE_SYSTEM:
        _fail(f"coordinate_system must be {COORDINATE_SYSTEM!r}.")
    for policy_field in ("exif_policy", "pii_policy", "created_at"):
        val = data.get(policy_field)
        if not isinstance(val, str) or len(val.strip()) < 10:
            _fail(f"{policy_field} must be a non-empty descriptive string.")

    _walk_for_forbidden_keys(data)

    top_annotator = data.get("annotator_id")
    if not isinstance(top_annotator, str) or not SAFE_REVIEWER_RE.fullmatch(top_annotator):
        _fail("annotator_id must be a non-identifying ASCII code (1-32 letters, digits, '_' or '-').")

    samples = data.get("samples")
    if not isinstance(samples, list) or not samples:
        _fail("samples must be a non-empty list.")

    seen_images: set[str] = set()
    seen_codes: set[str] = set()
    seen_doc_ids: set[str] = set()
    seen_suggestion_ids: set[str] = set()

    counts: dict[str, Any] = {
        "schema_version": version,
        "samples": len(samples),
        "decoded_ok": 0,
        "decode_failed": 0,
        "annotatable_images": 0,
        "human_completed_images": 0,
        "second_reviewed_images": 0,
        "status_counts": {key: 0 for key in sorted(ANNOTATION_STATUS)},
        "suitability_counts": {key: 0 for key in sorted(SUITABILITY_STATUS)},
        "source_counts": {key: 0 for key in sorted(IMAGE_SOURCES)},
        "quality_level_counts": {key: 0 for key in sorted(IMAGE_QUALITY_LEVELS)},
        "exclusion_reason_counts": {},
        "second_review_status_counts": {key: 0 for key in sorted(SECOND_REVIEW_STATUS)},
        "background_images": 0,
        "documents": 0,
        "human_verified_documents": 0,
        "ai_suggestions": 0,
        "scorable_boundary_samples": 0,
        "scorable_four_corner_documents": 0,
        "scorable_visible_polygon_documents": 0,
        "unscorable_boundary_documents": 0,
        "incomplete_documents": 0,
        "kind_counts": {kind: 0 for kind in sorted(KINDS)},
        "boundary_status_counts": {bs: 0 for bs in sorted(BOUNDARY_STATUS)},
        "difficulty_flag_counts": {df: 0 for df in sorted(DIFFICULTY_FLAGS)},
        "capture_groups": set(),
        "without_group": 0,
        "near_duplicate_clusters": set(),
    }

    for idx, sample in enumerate(samples, start=1):
        where = f"sample {idx}"
        if not isinstance(sample, dict):
            _fail(f"{where} must be an object.")

        image_id = sample.get("image_id")
        if not isinstance(image_id, str) or not IMAGE_ID_RE.fullmatch(image_id):
            _fail(f"{where} has an invalid 64-hex SHA-256 image_id.")
        if image_id in seen_images:
            _fail(f"{where} duplicates an image_id.")
        seen_images.add(image_id)

        internal_code = sample.get("internal_code", "")
        if not isinstance(internal_code, str) or (
            internal_code and not INTERNAL_CODE_RE.fullmatch(internal_code)
        ):
            _fail(f"{where} internal_code must be empty or match e.g. 'IMG-01'.")
        if internal_code:
            if internal_code in seen_codes:
                _fail(f"{where} duplicates an internal_code.")
            seen_codes.add(internal_code)

        fmt = sample.get("image_format")
        if fmt not in IMAGE_FORMATS:
            _fail(f"{where} has an unsupported image_format.")
        decode = sample.get("decode_status")
        if decode not in DECODE_STATUS:
            _fail(f"{where} has an unsupported decode_status.")

        raw_w = sample.get("raw_width_px")
        raw_h = sample.get("raw_height_px")
        exif_orient = sample.get("exif_orientation")
        width_px = sample.get("width_px")
        height_px = sample.get("height_px")
        if not all(_is_int(v) for v in (raw_w, raw_h, exif_orient, width_px, height_px)):
            _fail(f"{where} dimensions and exif_orientation must be integers.")
        if exif_orient not in range(0, 9):
            _fail(f"{where} exif_orientation must be between 0 and 8.")

        ann_status = sample.get("annotation_status")
        if ann_status not in ANNOTATION_STATUS:
            _fail(f"{where} has an unsupported annotation_status.")
        suitability = sample.get("suitability_status")
        if suitability not in SUITABILITY_STATUS:
            _fail(f"{where} has an unsupported suitability_status.")
        exclusion = sample.get("exclusion_reason", "")
        if exclusion not in EXCLUSION_REASONS:
            _fail(f"{where} has an unsupported exclusion_reason.")

        if decode == "ok":
            counts["decoded_ok"] += 1
            if raw_w <= 0 or raw_h <= 0 or width_px <= 0 or height_px <= 0:
                _fail(f"{where} decoded image dimensions must be positive.")
            exp_w, exp_h = expected_oriented_dimensions(raw_w, raw_h, exif_orient)
            if (width_px, height_px) != (exp_w, exp_h):
                _fail(
                    f"{where} width_px/height_px ({width_px}x{height_px}) inconsistent with "
                    f"raw dimensions ({raw_w}x{raw_h}) and exif_orientation={exif_orient}."
                )
        else:
            counts["decode_failed"] += 1
            if any(v != 0 for v in (raw_w, raw_h, width_px, height_px)):
                _fail(f"{where} decode failure must record zero dimensions.")
            if ann_status != "excluded" or exclusion != "decode_failed" or suitability != "unreadable":
                _fail(
                    f"{where} decode failure must have annotation_status='excluded', "
                    "exclusion_reason='decode_failed', and suitability_status='unreadable'."
                )

        if ann_status == "excluded":
            if not exclusion:
                _fail(f"{where} marked excluded must specify a non-empty exclusion_reason.")
            counts["exclusion_reason_counts"][exclusion] = (
                counts["exclusion_reason_counts"].get(exclusion, 0) + 1
            )
        elif exclusion:
            _fail(f"{where} has an exclusion_reason while annotation_status is not 'excluded'.")

        if suitability == "unreadable" and ann_status in {"annotated", "second_review"}:
            _fail(f"{where} marked unreadable cannot be marked annotated/second_review; exclude it instead.")

        dhash = sample.get("perceptual_dhash64", "")
        if not isinstance(dhash, str) or (dhash and not DHASH64_RE.fullmatch(dhash)):
            _fail(f"{where} perceptual_dhash64 must be empty or 16 lowercase hex chars.")
        cluster = sample.get("near_duplicate_cluster_id", "")
        if not isinstance(cluster, str) or (cluster and not SAFE_CLUSTER_RE.fullmatch(cluster)):
            _fail(f"{where} near_duplicate_cluster_id must be empty or a safe ASCII code.")
        if cluster:
            counts["near_duplicate_clusters"].add(cluster)

        img_source = sample.get("image_source")
        if img_source not in IMAGE_SOURCES:
            _fail(f"{where} has an unsupported image_source.")
        group = sample.get("capture_group_id", "")
        if not isinstance(group, str) or (group and not SAFE_GROUP_RE.fullmatch(group)):
            _fail(f"{where} capture_group_id must be empty or a non-identifying ASCII code.")
        if group:
            counts["capture_groups"].add(group)
        elif ann_status != "excluded":
            counts["without_group"] += 1

        q_level = sample.get("image_quality_level")
        if q_level not in IMAGE_QUALITY_LEVELS:
            _fail(f"{where} has an unsupported image_quality_level.")
        diff_reasons = sample.get("difficulty_reasons")
        if (
            not isinstance(diff_reasons, list)
            or any(r not in DIFFICULTY_FLAGS for r in diff_reasons)
            or len(set(diff_reasons)) != len(diff_reasons)
        ):
            _fail(f"{where} has invalid or duplicate difficulty_reasons.")

        sample_annotator = sample.get("annotator_id", "")
        annotated_at = sample.get("annotated_at", "")
        if not isinstance(sample_annotator, str) or (
            sample_annotator and not SAFE_REVIEWER_RE.fullmatch(sample_annotator)
        ):
            _fail(f"{where} annotator_id must be empty or a safe ASCII reviewer code.")
        if not isinstance(annotated_at, str) or len(annotated_at) > 40:
            _fail(f"{where} annotated_at must be an ISO timestamp string or empty.")
        if ann_status in {"annotated", "second_review"} and (not sample_annotator or not annotated_at):
            _fail(f"{where} marked {ann_status} must record annotator_id and annotated_at.")

        sr = _validate_second_review(
            sample.get("second_review"),
            where,
            annotation_status=ann_status,
            primary_annotator=sample_annotator,
        )

        no_doc = sample.get("no_document")
        doc_count = sample.get("document_count")
        docs = sample.get("documents")
        if not isinstance(no_doc, bool) or not _is_int(doc_count) or not isinstance(docs, list):
            _fail(f"{where} has invalid no_document / document_count / documents fields.")
        if doc_count != len(docs):
            _fail(f"{where} document_count ({doc_count}) does not match len(documents) ({len(docs)}).")
        if no_doc and doc_count != 0:
            _fail(f"{where} with no_document=true must have zero documents.")
        if ann_status in {"annotated", "second_review"} and not no_doc and doc_count == 0:
            _fail(f"{where} marked {ann_status} with no_document=false must annotate at least 1 document.")
        if ann_status == "excluded" and any(d.get("human_verified") for d in docs if isinstance(d, dict)):
            # Excluded samples are permitted to keep empty documents=[] (preferred)
            # or uncounted draft notes, never counted as scorable ground truth.
            pass

        ai_suggestions = sample.get("ai_suggestions", [])
        if not isinstance(ai_suggestions, list):
            _fail(f"{where}.ai_suggestions must be a list.")
        for s_idx, suggestion in enumerate(ai_suggestions, start=1):
            _validate_ai_suggestion(
                suggestion,
                f"{where}, ai_suggestion {s_idx}",
                seen_suggestion_ids,
                width_px,
                height_px,
            )
        counts["ai_suggestions"] += len(ai_suggestions)

        counts["status_counts"][ann_status] += 1
        counts["suitability_counts"][suitability] += 1
        counts["source_counts"][img_source] += 1
        counts["quality_level_counts"][q_level] += 1
        counts["second_review_status_counts"][sr["status"]] += 1

        if decode == "ok" and suitability in {"annotatable", "needs_review"} and ann_status != "excluded":
            counts["annotatable_images"] += 1
        if ann_status in {"annotated", "second_review"}:
            counts["human_completed_images"] += 1
        if sr["status"] in {"agreed", "disputed", "resolved", "excluded_after_dispute"}:
            counts["second_reviewed_images"] += 1
        if no_doc and ann_status != "excluded":
            counts["background_images"] += 1

        for flag in diff_reasons:
            counts["difficulty_flag_counts"][flag] += 1

        sample_eligible_for_boundary = (
            decode == "ok"
            and ann_status in {"annotated", "second_review"}
            and suitability != "unreadable"
            and sr["status"] not in {"disputed", "excluded_after_dispute"}
            and sr["dispute_status"] not in {"open_dispute", "excluded_unresolvable"}
        )

        sample_has_scorable_doc = False
        has_hard_case = bool(diff_reasons) or doc_count > 1

        for d_idx, doc in enumerate(docs, start=1):
            outline_ok, four_ok, _, _ = _validate_document(
                doc,
                f"{where}, document {d_idx}",
                annotation_status=ann_status,
                width_px=width_px,
                height_px=height_px,
                seen_doc_ids=seen_doc_ids,
            )
            counts["documents"] += 1
            if doc["human_verified"] and ann_status in {"annotated", "second_review"}:
                counts["human_verified_documents"] += 1
            counts["kind_counts"][doc["document_kind"]] += 1
            counts["boundary_status_counts"][doc["boundary_status"]] += 1
            if doc["boundary_status"] != "complete" or doc["document_kind"] == "unknown" or doc["quality_flags"]:
                has_hard_case = True

            if doc["boundary_status"] == "undeterminable":
                counts["unscorable_boundary_documents"] += 1
            elif not outline_ok:
                counts["incomplete_documents"] += 1
                if ann_status in {"annotated", "second_review"}:
                    _fail(f"{where}, document {d_idx} is missing a complete measured outline.")
            elif sample_eligible_for_boundary:
                sample_has_scorable_doc = True
                counts["scorable_visible_polygon_documents"] += 1
                if four_ok and doc["boundary_status"] == "complete":
                    counts["scorable_four_corner_documents"] += 1
            else:
                counts["unscorable_boundary_documents"] += 1

        if sample_eligible_for_boundary and (sample_has_scorable_doc or no_doc):
            counts["scorable_boundary_samples"] += 1

        if require_complete:
            if ann_status in {"unannotated", "in_progress"}:
                _fail(f"{where} has incomplete annotation_status={ann_status!r}.")
            if sr["status"] == "disputed" or sr["dispute_status"] == "open_dispute":
                _fail(f"{where} has an unresolved reviewer dispute.")
            if ann_status != "excluded" and has_hard_case and sr["status"] not in {"agreed", "resolved"}:
                _fail(f"{where} is a difficult/multi-doc/partial case and requires completed second_review.")

    if require_complete:
        if counts["human_completed_images"] == 0:
            _fail("dataset contains zero human-completed images.")
        if counts["without_group"] > 0:
            _fail("every non-excluded sample requires a known capture_group_id before split creation.")
        if counts["incomplete_documents"] > 0:
            _fail("all non-excluded documents with determinable boundaries must have complete polygons.")
        if counts["second_reviewed_images"] == 0:
            _fail("at least one independent second review is required before benchmark freeze.")

    if images_dir is not None:
        counts["image_verification"] = verify_referenced_images(data, images_dir)

    counts["capture_groups"] = len(counts["capture_groups"])
    counts["near_duplicate_clusters"] = len(counts["near_duplicate_clusters"])
    return data, counts


def load_and_validate(
    path: Path,
    *,
    require_complete: bool = False,
    images_dir: Path | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        raw_text = path.read_text(encoding="utf-8")
        data = json.loads(raw_text)
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError("annotation file cannot be read as UTF-8 JSON.") from exc
    return validate_payload(data, require_complete=require_complete, images_dir=images_dir)


def save_annotations(
    payload: dict[str, Any],
    output_path: Path,
    *,
    require_complete: bool = False,
    allow_outside_local_data_in_tests: bool = False,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Validate, write UTF-8 JSON safely, and reload to guarantee lossless persistence."""
    validate_payload(payload, require_complete=require_complete)
    resolved = output_path.resolve()
    repo_root = ROOT.resolve()
    local_data_root = (ROOT / "local-data").resolve()
    if not allow_outside_local_data_in_tests:
        try:
            resolved.relative_to(repo_root)
            in_repo = True
        except ValueError:
            in_repo = False
        if in_repo and not resolved.is_relative_to(local_data_root):
            _fail("annotation files inside the repository must be saved under ignored local-data/.")
    resolved.parent.mkdir(parents=True, exist_ok=True)
    serialized = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    resolved.write_text(serialized, encoding="utf-8")
    reloaded, summary = load_and_validate(resolved, require_complete=require_complete)
    if reloaded != payload:
        _fail("round-trip reload differed from saved payload.")
    return reloaded, summary


# ---------------------------------------------------------------------------
# Blind Two-Reviewer Comparison & Dispute Detection
# ---------------------------------------------------------------------------


def _max_iou_pairs(
    a: list[tuple[dict[str, Any], list[tuple[float, float]] | None]],
    b: list[tuple[dict[str, Any], list[tuple[float, float]] | None]],
) -> list[tuple[int, int, float]]:
    if not a or not b:
        return []
    if len(a) > 8 or len(b) > 8:
        candidates = sorted(
            (
                (polygon_iou(x[1], y[1]), i, j)
                for i, x in enumerate(a)
                if x[1] is not None
                for j, y in enumerate(b)
                if y[1] is not None
            ),
            reverse=True,
        )
        used_a: set[int] = set()
        used_b: set[int] = set()
        result: list[tuple[int, int, float]] = []
        for score, i, j in candidates:
            if i not in used_a and j not in used_b:
                used_a.add(i)
                used_b.add(j)
                result.append((i, j, score))
        return result

    best_score = -1.0
    best: list[tuple[int, int, float]] = []

    def search(i: int, used: set[int], pairs: list[tuple[int, int, float]], score: float) -> None:
        nonlocal best_score, best
        if i == len(a):
            if score > best_score:
                best_score = score
                best = pairs[:]
            return
        search(i + 1, used, pairs, score)
        if a[i][1] is None:
            return
        for j, item in enumerate(b):
            if j in used or item[1] is None:
                continue
            value = polygon_iou(a[i][1], item[1])
            used.add(j)
            pairs.append((i, j, value))
            search(i + 1, used, pairs, score + value)
            pairs.pop()
            used.remove(j)

    search(0, set(), [], 0.0)
    return best


def compare(
    left: dict[str, Any],
    right: dict[str, Any],
    polygon_iou_threshold: float,
) -> dict[str, Any]:
    """Compare two independent human reviews without auto-selecting or averaging."""
    if left.get("annotator_id") == right.get("annotator_id"):
        _fail("the two independent review files must have different annotator_id codes.")
    if not _is_num(polygon_iou_threshold) or not (0.0 <= float(polygon_iou_threshold) <= 1.0):
        _fail("the pre-registered polygon IoU review threshold must be between 0 and 1.")

    amap = {sample["image_id"]: sample for sample in left["samples"]}
    bmap = {sample["image_id"]: sample for sample in right["samples"]}
    common = sorted(set(amap) & set(bmap))

    result: dict[str, Any] = {
        "common_samples": len(common),
        "missing_from_second": len(set(amap) - set(bmap)),
        "missing_from_first": len(set(bmap) - set(amap)),
        "image_source_disagreements": 0,
        "capture_group_disagreements": 0,
        "annotation_status_disagreements": 0,
        "exclusion_reason_disagreements": 0,
        "decode_status_disagreements": 0,
        "dimension_disagreements": 0,
        "document_count_disagreements": 0,
        "background_disagreements": 0,
        "kind_disagreements": 0,
        "boundary_status_disagreements": 0,
        "crop_quality_disagreements": 0,
        "quality_flag_disagreements": 0,
        "boundary_availability_disagreements": 0,
        "unmatched_outline_documents": 0,
        "polygon_iou_below_threshold": 0,
        "polygon_iou_review_threshold": float(polygon_iou_threshold),
        "matched_documents": 0,
        "mean_polygon_iou": None,
        "max_corner_drift_norm": None,
        "disputed_sample_count": 0,
        "reviewer_ids_differ": True,
        "auto_merged_or_averaged": False,
    }

    ious: list[float] = []
    corner_drifts: list[float] = []

    for image_id in common:
        a, b = amap[image_id], bmap[image_id]
        sample_disputed = False
        for key, metric in (
            ("image_source", "image_source_disagreements"),
            ("capture_group_id", "capture_group_disagreements"),
            ("annotation_status", "annotation_status_disagreements"),
            ("exclusion_reason", "exclusion_reason_disagreements"),
            ("decode_status", "decode_status_disagreements"),
        ):
            if a.get(key) != b.get(key):
                result[metric] += 1
                sample_disputed = True
        if (a.get("width_px"), a.get("height_px"), a.get("exif_orientation")) != (
            b.get("width_px"),
            b.get("height_px"),
            b.get("exif_orientation"),
        ):
            result["dimension_disagreements"] += 1
            sample_disputed = True
        if len(a["documents"]) != len(b["documents"]):
            result["document_count_disagreements"] += 1
            sample_disputed = True
        if a["no_document"] != b["no_document"]:
            result["background_disagreements"] += 1
            sample_disputed = True

        def prepared(sample: dict[str, Any]) -> list[tuple[dict[str, Any], list[tuple[float, float]] | None]]:
            items: list[tuple[dict[str, Any], list[tuple[float, float]] | None]] = []
            for document in sample["documents"]:
                poly = (
                    [(float(pt[0]), float(pt[1])) for pt in document["visible_polygon"]]
                    if len(document.get("visible_polygon", [])) >= 3
                    else None
                )
                items.append((document, poly))
            return items

        ap, bp = prepared(a), prepared(b)
        avail_a = sum(poly is not None for _, poly in ap)
        avail_b = sum(poly is not None for _, poly in bp)
        if avail_a != avail_b:
            result["boundary_availability_disagreements"] += 1
            sample_disputed = True

        pairs = _max_iou_pairs(ap, bp)
        matched_a = {i for i, _, _ in pairs}
        matched_b = {j for _, j, _ in pairs}
        result["matched_documents"] += len(pairs)
        unmatched = (avail_a - sum(ap[i][1] is not None for i in matched_a)) + (
            avail_b - sum(bp[j][1] is not None for j in matched_b)
        )
        if unmatched:
            result["unmatched_outline_documents"] += unmatched
            sample_disputed = True

        for i, j, iou_val in pairs:
            da, db = ap[i][0], bp[j][0]
            if da["document_kind"] != db["document_kind"]:
                result["kind_disagreements"] += 1
                sample_disputed = True
            if da["boundary_status"] != db["boundary_status"]:
                result["boundary_status_disagreements"] += 1
                sample_disputed = True
            if da["crop_quality"] != db["crop_quality"]:
                result["crop_quality_disagreements"] += 1
                sample_disputed = True
            if set(da["quality_flags"]) != set(db["quality_flags"]):
                result["quality_flag_disagreements"] += 1
                sample_disputed = True
            if iou_val < polygon_iou_threshold:
                result["polygon_iou_below_threshold"] += 1
                sample_disputed = True
            ious.append(iou_val)
            if da.get("corners") and db.get("corners"):
                drift = max(
                    math.dist(
                        (float(da["corners"][k][0]), float(da["corners"][k][1])),
                        (float(db["corners"][k][0]), float(db["corners"][k][1])),
                    )
                    for k in range(4)
                )
                corner_drifts.append(drift)

        if sample_disputed:
            result["disputed_sample_count"] += 1

    if ious:
        result["mean_polygon_iou"] = round(sum(ious) / len(ious), 6)
    if corner_drifts:
        result["max_corner_drift_norm"] = round(max(corner_drifts), 6)
    return result


def build_dispute_queue(
    left: dict[str, Any],
    right: dict[str, Any],
    polygon_iou_threshold: float,
) -> dict[str, Any]:
    """Create a local-only adjudication queue marking disagreements as open_dispute.

    Never selects one reviewer's polygon automatically and never averages polygons.
    Must be stored only under ignored local-data/.
    """
    metrics = compare(left, right, polygon_iou_threshold)
    amap = {s["image_id"]: s for s in left["samples"]}
    bmap = {s["image_id"]: s for s in right["samples"]}
    queue_entries: list[dict[str, Any]] = []

    for image_id in sorted(set(amap) | set(bmap)):
        if image_id not in amap or image_id not in bmap:
            queue_entries.append(
                {
                    "image_id": image_id,
                    "internal_code": (amap.get(image_id) or bmap.get(image_id, {})).get("internal_code", ""),
                    "dispute_status": "open_dispute",
                    "reasons": ["missing_from_one_reviewer"],
                }
            )
            continue
        single_left = {**left, "samples": [amap[image_id]]}
        single_right = {**right, "samples": [bmap[image_id]]}
        single_cmp = compare(single_left, single_right, polygon_iou_threshold)
        reasons = [
            key
            for key in (
                "image_source_disagreements",
                "capture_group_disagreements",
                "annotation_status_disagreements",
                "exclusion_reason_disagreements",
                "document_count_disagreements",
                "background_disagreements",
                "kind_disagreements",
                "boundary_status_disagreements",
                "crop_quality_disagreements",
                "quality_flag_disagreements",
                "boundary_availability_disagreements",
                "unmatched_outline_documents",
                "polygon_iou_below_threshold",
            )
            if single_cmp[key] > 0
        ]
        queue_entries.append(
            {
                "image_id": image_id,
                "internal_code": amap[image_id].get("internal_code", ""),
                "dispute_status": "open_dispute" if reasons else "none",
                "reasons": reasons,
            }
        )

    return {
        "schema": "scan-id-local-dispute-queue-v2",
        "polygon_iou_review_threshold": polygon_iou_threshold,
        "auto_resolution_applied": False,
        "aggregate_metrics": metrics,
        "items": queue_entries,
    }


def migrate_v1_to_v2(v1: dict[str, Any]) -> dict[str, Any]:
    """Upgrade a legacy scan-id-local-annotations-v1 draft into v2 without OCR PII."""
    if not isinstance(v1, dict) or v1.get("schema") != LEGACY_SCHEMA_V1:
        _fail("input is not a scan-id-local-annotations-v1 payload.")
    reviewer = str(v1.get("reviewer_id", "R1"))
    created_at = str(v1.get("created_at", "2026-10-26T00:00:00Z"))
    vis_map = {
        "fully_visible": "complete",
        "partially_occluded": "occluded",
        "truncated": "partial",
        "unscorable": "undeterminable",
    }
    flag_map = {
        "blur": "blur",
        "glare": "glare",
        "low_light": "low_light",
        "perspective": "severe_perspective",
        "occlusion": "occlusion",
        "compression": "compression",
        "other": "other",
    }
    v2_samples: list[dict[str, Any]] = []
    for idx, old in enumerate(v1.get("samples", []), start=1):
        img_id = str(old.get("sample_id", ""))
        decode = str(old.get("decode_status", "ok"))
        w = int(old.get("width_px", 0))
        h = int(old.get("height_px", 0))
        old_status = str(old.get("review_status", "pending"))
        old_adj = str(old.get("adjudication_status", "not_adjudicated"))
        if decode == "failed":
            ann_status = "excluded"
            excl = "decode_failed"
            suitability = "unreadable"
        elif old_status == "unscorable":
            ann_status = "excluded"
            excl = "boundary_unscorable"
            suitability = "unreadable"
        elif old_status == "reviewed" and old_adj == "adjudicated":
            ann_status = "second_review"
            excl = ""
            suitability = "annotatable"
        elif old_status == "reviewed":
            ann_status = "annotated"
            excl = ""
            suitability = "annotatable"
        elif old_status == "uncertain":
            ann_status = "in_progress"
            excl = ""
            suitability = "needs_review"
        else:
            ann_status = "unannotated"
            excl = ""
            suitability = "annotatable"

        docs_v2: list[dict[str, Any]] = []
        for d_idx, d_old in enumerate(old.get("documents", []), start=1):
            b_stat = vis_map.get(str(d_old.get("visibility", "fully_visible")), "undeterminable")
            poly = copy.deepcopy(d_old.get("visible_polygon", [])) if b_stat != "undeterminable" else []
            quad = copy.deepcopy(d_old.get("quadrilateral")) if b_stat == "complete" else None
            if b_stat == "complete" and quad is None and len(poly) == 4:
                quad = copy.deepcopy(poly)
            mapped_flags = sorted({flag_map[f] for f in d_old.get("quality_flags", []) if f in flag_map})
            docs_v2.append(
                {
                    "document_id": f"{img_id[:12]}-doc-{d_idx:02d}",
                    "label_origin": "human_manual",
                    "human_verified": ann_status in {"annotated", "second_review"},
                    "document_kind": str(d_old.get("document_kind", "unknown")),
                    "boundary_status": b_stat,
                    "corners": quad,
                    "visible_polygon": poly,
                    "crop_quality": str(d_old.get("crop_quality", "uncertain")),
                    "quality_flags": mapped_flags,
                }
            )

        sr_obj = {
            "status": "resolved" if ann_status == "second_review" else "not_started",
            "reviewer_id": "R2" if ann_status == "second_review" else "",
            "reviewed_at": created_at if ann_status == "second_review" else "",
            "dispute_status": "resolved_by_protocol" if ann_status == "second_review" else "none",
            "adjudicator_id": reviewer if ann_status == "second_review" else "",
            "adjudicated_at": created_at if ann_status == "second_review" else "",
            "resolution_code": "unanimous_primary_and_secondary" if ann_status == "second_review" else "",
        }

        v2_samples.append(
            {
                "image_id": img_id,
                "internal_code": f"IMG-{idx:02d}",
                "image_format": "jpeg" if decode == "ok" else "unknown",
                "decode_status": decode,
                "raw_width_px": w,
                "raw_height_px": h,
                "exif_orientation": 1 if decode == "ok" else 0,
                "width_px": w,
                "height_px": h,
                "perceptual_dhash64": "",
                "near_duplicate_cluster_id": "",
                "image_source": "unknown",
                "capture_group_id": str(old.get("capture_group_id", "")),
                "suitability_status": suitability,
                "annotation_status": ann_status,
                "exclusion_reason": excl,
                "image_quality_level": "unassessed",
                "difficulty_reasons": [],
                "annotator_id": reviewer if ann_status in {"annotated", "second_review"} else "",
                "annotated_at": created_at if ann_status in {"annotated", "second_review"} else "",
                "second_review": sr_obj,
                "no_document": bool(old.get("no_document", False)),
                "document_count": 0 if old.get("no_document", False) else len(docs_v2),
                "documents": [] if old.get("no_document", False) else docs_v2,
                "ai_suggestions": [],
            }
        )

    return {
        "schema": SCHEMA,
        "schema_version": "2.0.0",
        "annotator_id": reviewer,
        "created_at": created_at,
        "coordinate_system": COORDINATE_SYSTEM,
        "exif_policy": "apply EXIF orientation (tag 274) before display and measurement; coordinates normalized to [0, 1]",
        "pii_policy": "boundary and document-kind labels only; never store personal names, ID numbers, filenames, or OCR text",
        "samples": v2_samples,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("annotations", type=Path, help="local v2 JSON export from an annotator")
    parser.add_argument("--images-dir", type=Path, help="optional local image directory to verify file existence, decode integrity, EXIF, and dHash")
    parser.add_argument("--compare", type=Path, help="optional second independent reviewer JSON")
    parser.add_argument(
        "--polygon-iou-review-threshold",
        type=float,
        help="pre-registered inter-reviewer boundary agreement threshold in [0, 1]; required with --compare",
    )
    parser.add_argument(
        "--write-disputes",
        type=Path,
        help="optional path under ignored local-data/ to save the non-PII adjudication queue when --compare is used",
    )
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="fail for unannotated/in-progress samples, missing capture groups, open disputes, or missing hard-case second review",
    )
    args = parser.parse_args()

    if args.compare and args.polygon_iou_review_threshold is None:
        parser.error("--compare requires --polygon-iou-review-threshold fixed before inspecting reviewer results")
    if args.polygon_iou_review_threshold is not None and not (0.0 <= args.polygon_iou_review_threshold <= 1.0):
        parser.error("--polygon-iou-review-threshold must be between 0 and 1")
    if args.write_disputes and not args.compare:
        parser.error("--write-disputes requires --compare")

    try:
        data, counts = load_and_validate(
            args.annotations,
            require_complete=args.require_complete,
            images_dir=args.images_dir,
        )
        print(
            f"PASS: schema {SCHEMA} (v{counts['schema_version']}) and geometry valid for "
            f"{counts['samples']} image(s); annotator code accepted (redacted)."
        )
        print(
            "Status summary: "
            + ", ".join(f"{k}={v}" for k, v in sorted(counts["status_counts"].items()))
            + f", human_completed={counts['human_completed_images']}, second_reviewed={counts['second_reviewed_images']}."
        )
        print(
            f"Boundary eligibility: scorable_samples={counts['scorable_boundary_samples']}, "
            f"scorable_4corner_docs={counts['scorable_four_corner_documents']}, "
            f"scorable_visible_poly_docs={counts['scorable_visible_polygon_documents']}, "
            f"unscorable_docs={counts['unscorable_boundary_documents']}, "
            f"ai_suggestions_kept_separate={counts['ai_suggestions']}."
        )
        print(
            "Document-kind counts: "
            + ", ".join(f"{kind}={count}" for kind, count in sorted(counts["kind_counts"].items()))
        )
        if "image_verification" in counts:
            iv = counts["image_verification"]
            print(
                f"On-disk image verification: indexed={iv['disk_images_indexed']}, "
                f"decoded_ok={iv['verified_decoded_ok']}, decode_failed={iv['verified_decode_failed']}."
            )

        if args.compare:
            other, other_counts = load_and_validate(
                args.compare,
                require_complete=args.require_complete,
                images_dir=args.images_dir,
            )
            queue = build_dispute_queue(data, other, args.polygon_iou_review_threshold)
            metrics = queue["aggregate_metrics"]
            print(
                f"Second reviewer code accepted (redacted); samples={other_counts['samples']}; "
                f"human_completed={other_counts['human_completed_images']}."
            )
            print("Blind agreement summary (no image IDs or PII): " + json.dumps(metrics, sort_keys=True))

            if args.write_disputes:
                out_path = args.write_disputes.resolve()
                local_data_root = (ROOT / "local-data").resolve()
                try:
                    out_path.relative_to(ROOT.resolve())
                    in_repo = True
                except ValueError:
                    in_repo = False
                if in_repo and not out_path.is_relative_to(local_data_root):
                    raise ValidationError("dispute queues inside the repository must stay under ignored local-data/.")
                out_path.parent.mkdir(parents=True, exist_ok=True)
                out_path.write_text(json.dumps(queue, indent=2) + "\n", encoding="utf-8")

            disagreement_keys = (
                "missing_from_second",
                "missing_from_first",
                "image_source_disagreements",
                "capture_group_disagreements",
                "annotation_status_disagreements",
                "exclusion_reason_disagreements",
                "decode_status_disagreements",
                "dimension_disagreements",
                "document_count_disagreements",
                "background_disagreements",
                "kind_disagreements",
                "boundary_status_disagreements",
                "crop_quality_disagreements",
                "quality_flag_disagreements",
                "boundary_availability_disagreements",
                "unmatched_outline_documents",
                "polygon_iou_below_threshold",
            )
            disagreements = sum(int(metrics[key]) for key in disagreement_keys)
            if disagreements:
                print(
                    f"REVIEW REQUIRED: {disagreements} aggregate disagreement(s) across "
                    f"{metrics['disputed_sample_count']} sample(s); resolve via protocol or exclude unscorable items.",
                    file=sys.stderr,
                )
                return 2

        if not args.require_complete and (
            counts["status_counts"]["unannotated"]
            or counts["status_counts"]["in_progress"]
            or counts["incomplete_documents"]
        ):
            print("NOTICE: incomplete annotation draft; do not use for model evaluation, training, or threshold tuning.")
        return 0
    except ValidationError as exc:
        print(f"FAIL: local annotation validation: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
