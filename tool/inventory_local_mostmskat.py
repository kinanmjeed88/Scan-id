#!/usr/bin/env python3
"""Build a local-only inventory and unannotated v2 seed for Mostmskat/.

Privacy guarantees:
- Reads local files offline only; never makes network calls.
- Private inventory (containing local relative paths, SHA-256 image IDs, and
  64-bit perceptual dHashes) is restricted to ignored `local-data/`.
- Redacted summary and stdout contain aggregate counts and non-identifying
  distributions only — never filenames, paths, content hashes, or personal text.
- Never treats `.scanid` backup crops/suggestions or legacy detector proposals
  as human ground truth, and never treats video frames or near-duplicates as
  independent samples.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np
from PIL import ExifTags, Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tool.validate_local_annotations import (  # noqa: E402
    COORDINATE_SYSTEM,
    SCHEMA,
    compute_dhash64_hex,
    dhash64_hamming,
    expected_oriented_dimensions,
    save_annotations,
)

DEFAULT_INPUT_DIR = ROOT / "Mostmskat"
DEFAULT_INVENTORY_OUT = ROOT / "local-data" / "mostmskat-local-inventory.json"
DEFAULT_SEED_OUT = ROOT / "local-data" / "mostmskat-unannotated-seed-v2.json"
DEFAULT_REDACTED_OUT = ROOT / "local-data" / "mostmskat-redacted-summary.json"

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
VIDEO_SUFFIXES = {".mp4", ".mov", ".avi", ".mkv", ".webm"}
SCANID_MAGIC = b"SCANID-BACKUP-1\n"
EXIF_TAGS = {k: v for k, v in ExifTags.TAGS.items()}


def _ensure_under_local_data(path: Path, *, allow_temp_in_tests: bool = False) -> Path:
    resolved = path.resolve()
    if allow_temp_in_tests:
        return resolved
    repo_root = ROOT.resolve()
    local_data_root = (ROOT / "local-data").resolve()
    try:
        resolved.relative_to(repo_root)
        in_repo = True
    except ValueError:
        in_repo = False
    if in_repo and not resolved.is_relative_to(local_data_root):
        raise ValueError(f"output inside repository must remain under ignored local-data/: {path}")
    return resolved


def _thumb_rgb(pil_img: Image.Image, size: int = 32) -> np.ndarray:
    oriented = ImageOps.exif_transpose(pil_img).convert("RGB").resize((size, size), Image.Resampling.BOX)
    return np.asarray(oriented, dtype=np.float32) / 255.0


def _infer_metadata_source_hint(path: Path, exif_tag_names: list[str], raw_w: int, raw_h: int) -> str:
    """Conservative non-PII metadata heuristic; human reviewer confirms final source."""
    stem_lower = path.stem.lower()
    if "screenshot" in stem_lower or ("Software" in exif_tag_names and "Make" not in exif_tag_names):
        return "screenshot"
    if any(k in exif_tag_names for k in ("Make", "Model", "DateTimeOriginal", "FocalLength")):
        return "camera_photo"
    if min(raw_w, raw_h) < 280:
        return "unknown"
    return "unknown"


def _infer_initial_suitability(decode_status: str, raw_w: int, raw_h: int, is_near_dup_secondary: bool) -> str:
    if decode_status != "ok":
        return "unreadable"
    if is_near_dup_secondary:
        return "needs_review"
    if min(raw_w, raw_h) < 280:
        return "unclear"
    return "annotatable"


def _inspect_scanid_backup(backup_path: Path, sha_to_internal: dict[str, str]) -> dict[str, Any]:
    size_bytes = backup_path.stat().st_size
    info: dict[str, Any] = {
        "internal_code": "ARC-01",
        "format": "scanid_backup",
        "size_bytes": size_bytes,
        "valid_header": False,
        "asset_count": 0,
        "stored_file_count": 0,
        "assets_byte_matching_still_images": 0,
        "matched_internal_codes": [],
        "unmatched_asset_count": 0,
        "contains_crops_or_suggestions": False,
        "treated_as_ground_truth": False,
    }
    with backup_path.open("rb") as handle:
        magic = handle.read(len(SCANID_MAGIC))
        if magic != SCANID_MAGIC:
            return info
        len_bytes = handle.read(4)
        if len(len_bytes) != 4:
            return info
        manifest_len = struct.unpack(">I", len_bytes)[0]
        if manifest_len <= 0 or manifest_len > 16 * 1024 * 1024:
            return info
        manifest = json.loads(handle.read(manifest_len).decode("utf-8"))

    info["valid_header"] = True
    project = manifest.get("project", {})
    files = manifest.get("files", [])
    assets = project.get("assets", [])
    path_to_sha = {
        str(entry.get("path", "")): str(entry.get("sha256", ""))
        for entry in files
        if isinstance(entry, dict)
    }
    matched_codes: list[str] = []
    unmatched = 0
    has_crops = False
    for asset in assets:
        if not isinstance(asset, dict):
            continue
        if asset.get("crop") or asset.get("suggestedCrop") or asset.get("cropDraft"):
            has_crops = True
        orig_sha = path_to_sha.get(str(asset.get("originalPath", "")), "")
        if orig_sha in sha_to_internal:
            matched_codes.append(sha_to_internal[orig_sha])
        else:
            unmatched += 1

    info["asset_count"] = len(assets)
    info["stored_file_count"] = len(files)
    info["assets_byte_matching_still_images"] = len(matched_codes)
    info["matched_internal_codes"] = sorted(set(matched_codes))
    info["unmatched_asset_count"] = unmatched
    info["contains_crops_or_suggestions"] = has_crops
    return info


def _inspect_video(
    video_path: Path,
    internal_code: str,
    still_dhashes: dict[str, str],
    still_thumbs: dict[str, np.ndarray],
) -> dict[str, Any]:
    size_bytes = video_path.stat().st_size
    info: dict[str, Any] = {
        "internal_code": internal_code,
        "format": video_path.suffix.lstrip(".").lower() or "video",
        "size_bytes": size_bytes,
        "decodable": False,
        "width_px": 0,
        "height_px": 0,
        "fps": 0.0,
        "frame_count": 0,
        "duration_sec": 0.0,
        "still_images_matching_frames": [],
        "treated_as_independent_samples": False,
    }
    try:
        import cv2
    except ImportError:
        return info

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        cap.release()
        return info
    fps = float(cap.get(cv2.CAP_PROP_FPS) or 0.0)
    fcount = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    vw = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
    vh = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
    info.update(
        {
            "decodable": vw > 0 and vh > 0 and fcount > 0,
            "width_px": vw,
            "height_px": vh,
            "fps": round(fps, 3),
            "frame_count": fcount,
            "duration_sec": round(fcount / fps, 3) if fps > 0 else 0.0,
        }
    )

    step = max(1, fcount // 60) if fcount > 0 else 10
    matched: set[str] = set()
    frame_idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if frame_idx % step == 0:
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            pil_frame = Image.fromarray(rgb)
            f_dhash = compute_dhash64_hex(pil_frame)
            f_thumb = _thumb_rgb(pil_frame)
            for code, s_dhash in still_dhashes.items():
                ham = dhash64_hamming(s_dhash, f_dhash)
                rot_l1 = min(
                    float(np.mean(np.abs(still_thumbs[code] - np.rot90(f_thumb, k))))
                    for k in range(4)
                )
                if ham <= 10 or rot_l1 < 0.06:
                    matched.add(code)
        frame_idx += 1
    cap.release()
    info["still_images_matching_frames"] = sorted(matched)
    return info


def build_inventory(input_dir: Path) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    """Return (private_inventory, unannotated_v2_seed, redacted_public_summary)."""
    if not input_dir.is_dir():
        raise FileNotFoundError("input directory does not exist.")

    all_files = sorted(p for p in input_dir.rglob("*") if p.is_file())
    still_paths: list[Path] = []
    video_paths: list[Path] = []
    archive_paths: list[Path] = []
    other_paths: list[Path] = []

    for path in all_files:
        suf = path.suffix.lower()
        if suf in IMAGE_SUFFIXES:
            still_paths.append(path)
        elif suf in VIDEO_SUFFIXES:
            video_paths.append(path)
        elif suf == ".scanid":
            archive_paths.append(path)
        else:
            other_paths.append(path)

    # Order still images deterministically by SHA-256; track byte-exact duplicates.
    raw_by_sha: dict[str, list[Path]] = {}
    for path in still_paths:
        sha = hashlib.sha256(path.read_bytes()).hexdigest()
        raw_by_sha.setdefault(sha, []).append(path)

    exact_duplicate_extra_files = sum(len(paths) - 1 for paths in raw_by_sha.values())
    unique_shas = sorted(raw_by_sha.keys())

    still_entries: list[dict[str, Any]] = []
    still_dhashes: dict[str, str] = {}
    still_thumbs: dict[str, np.ndarray] = {}
    sha_to_internal: dict[str, str] = {}

    for idx, sha in enumerate(unique_shas, start=1):
        code = f"IMG-{idx:02d}"
        sha_to_internal[sha] = code
        rep_path = sorted(raw_by_sha[sha])[0]
        rel_path = rep_path.relative_to(input_dir).as_posix()
        nbytes = rep_path.stat().st_size

        decode_status = "ok"
        integrity_ok = True
        img_fmt = "unknown"
        raw_w = raw_h = ord_w = ord_h = 0
        exif_orient = 0
        raw_exif_orient = None
        exif_tag_names: list[str] = []
        dhash_hex = ""

        try:
            with Image.open(rep_path) as probe:
                probe.verify()
            with Image.open(rep_path) as im:
                im.load()
                img_fmt = (im.format or "unknown").lower()
                if img_fmt == "jpg":
                    img_fmt = "jpeg"
                if img_fmt not in {"jpeg", "png", "webp", "bmp"}:
                    img_fmt = "unknown"
                raw_w, raw_h = im.size
                exif = im.getexif()
                if exif:
                    exif_tag_names = sorted(EXIF_TAGS.get(k, f"tag_{k}") for k in exif.keys())
                    raw_exif_orient = exif.get(274)
                exif_orient = int(raw_exif_orient) if isinstance(raw_exif_orient, int) and 0 <= raw_exif_orient <= 8 else 1
                exp_w, exp_h = expected_oriented_dimensions(raw_w, raw_h, exif_orient)
                oriented = ImageOps.exif_transpose(im)
                ord_w, ord_h = oriented.size
                if (ord_w, ord_h) != (exp_w, exp_h):
                    ord_w, ord_h = exp_w, exp_h
                dhash_hex = compute_dhash64_hex(im)
                still_dhashes[code] = dhash_hex
                still_thumbs[code] = _thumb_rgb(im)
        except Exception:
            decode_status = "failed"
            integrity_ok = False

        has_timestamp_exif = any(
            t in exif_tag_names for t in ("DateTime", "DateTimeOriginal", "DateTimeDigitized")
        )
        has_camera_exif = any(t in exif_tag_names for t in ("Make", "Model"))
        source_hint = (
            _infer_metadata_source_hint(rep_path, exif_tag_names, raw_w, raw_h)
            if decode_status == "ok"
            else "unknown"
        )

        still_entries.append(
            {
                "internal_code": code,
                "image_id": sha,
                "local_relpath": rel_path,
                "exact_duplicate_file_count": len(raw_by_sha[sha]),
                "file_extension": rep_path.suffix.lower(),
                "image_format": img_fmt,
                "size_bytes": nbytes,
                "decode_status": decode_status,
                "integrity_ok": integrity_ok,
                "raw_width_px": raw_w,
                "raw_height_px": raw_h,
                "exif_orientation": exif_orient,
                "exif_orientation_raw_tag": raw_exif_orient,
                "oriented_width_px": ord_w,
                "oriented_height_px": ord_h,
                "exif_tag_names": exif_tag_names,
                "has_capture_timestamp_exif": has_timestamp_exif,
                "has_camera_model_exif": has_camera_exif,
                "perceptual_dhash64": dhash_hex,
                "near_duplicate_cluster_id": "",
                "metadata_source_hint": source_hint,
                "human_verified_document_count": None,
                "suitability_status": "annotatable" if decode_status == "ok" else "unreadable",
            }
        )

    # Near-duplicate clustering across decodable still images
    codes = sorted(still_dhashes.keys())
    parent = {c: c for c in codes}

    def find(x: str) -> str:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a: str, b: str) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            if ra < rb:
                parent[rb] = ra
            else:
                parent[ra] = rb

    near_duplicate_pairs: list[dict[str, Any]] = []
    for i in range(len(codes)):
        for j in range(i + 1, len(codes)):
            ca, cb = codes[i], codes[j]
            ham = dhash64_hamming(still_dhashes[ca], still_dhashes[cb])
            rot_l1 = min(
                float(np.mean(np.abs(still_thumbs[ca] - np.rot90(still_thumbs[cb], k))))
                for k in range(4)
            )
            if ham <= 10 or rot_l1 < 0.06:
                union(ca, cb)
                near_duplicate_pairs.append(
                    {
                        "pair": [ca, cb],
                        "dhash64_hamming": ham,
                        "min_rotated_l1": round(rot_l1, 4),
                    }
                )

    clusters: dict[str, list[str]] = {}
    for c in codes:
        clusters.setdefault(find(c), []).append(c)
    multi_clusters = [ sorted(members) for members in clusters.values() if len(members) > 1 ]
    multi_clusters.sort()
    code_to_cluster: dict[str, str] = {}
    secondary_dups: set[str] = set()
    for c_idx, members in enumerate(multi_clusters, start=1):
        cid = f"dup-cluster-{c_idx:02d}"
        for m_idx, member in enumerate(members):
            code_to_cluster[member] = cid
            if m_idx > 0:
                secondary_dups.add(member)

    for entry in still_entries:
        code = entry["internal_code"]
        entry["near_duplicate_cluster_id"] = code_to_cluster.get(code, "")
        entry["suitability_status"] = _infer_initial_suitability(
            entry["decode_status"],
            entry["raw_width_px"],
            entry["raw_height_px"],
            code in secondary_dups,
        )

    video_reports = [
        _inspect_video(vp, f"VID-{idx:02d}", still_dhashes, still_thumbs)
        for idx, vp in enumerate(video_paths, start=1)
    ]
    archive_reports = [
        _inspect_scanid_backup(ap, sha_to_internal)
        for ap in archive_paths
    ]

    now_iso = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    # Build unannotated v2 seed ready for Local Annotation Studio
    seed_samples: list[dict[str, Any]] = []
    for entry in still_entries:
        code = entry["internal_code"]
        decode_ok = entry["decode_status"] == "ok"
        seed_samples.append(
            {
                "image_id": entry["image_id"],
                "internal_code": code,
                "image_format": entry["image_format"],
                "decode_status": entry["decode_status"],
                "raw_width_px": entry["raw_width_px"],
                "raw_height_px": entry["raw_height_px"],
                "exif_orientation": entry["exif_orientation"],
                "width_px": entry["oriented_width_px"],
                "height_px": entry["oriented_height_px"],
                "perceptual_dhash64": entry["perceptual_dhash64"],
                "near_duplicate_cluster_id": entry["near_duplicate_cluster_id"],
                "image_source": entry["metadata_source_hint"],
                "capture_group_id": "",
                "suitability_status": entry["suitability_status"],
                "annotation_status": "unannotated" if decode_ok else "excluded",
                "exclusion_reason": "" if decode_ok else "decode_failed",
                "image_quality_level": "unassessed",
                "difficulty_reasons": (
                    ["compression"]
                    if decode_ok and min(entry["raw_width_px"], entry["raw_height_px"]) < 280
                    else []
                ),
                "annotator_id": "",
                "annotated_at": "",
                "second_review": {
                    "status": "not_started",
                    "reviewer_id": "",
                    "reviewed_at": "",
                    "dispute_status": "none",
                    "adjudicator_id": "",
                    "adjudicated_at": "",
                    "resolution_code": "",
                },
                "no_document": False,
                "document_count": 0,
                "documents": [],
                "ai_suggestions": [],
            }
        )

    seed_v2: dict[str, Any] = {
        "schema": SCHEMA,
        "schema_version": "2.0.0",
        "annotator_id": "SEED_UNANNOTATED",
        "created_at": now_iso,
        "coordinate_system": COORDINATE_SYSTEM,
        "exif_policy": "apply EXIF orientation (tag 274) before display and measurement; coordinates are [x/width_px, y/height_px] in [0, 1]",
        "pii_policy": "boundary and document-kind labels only; never store personal names, ID numbers, filenames, or OCR text",
        "samples": seed_samples,
    }

    ext_counts = Counter(p.suffix.lower() or "<none>" for p in all_files)
    suitability_counts = Counter(e["suitability_status"] for e in still_entries)
    source_hint_counts = Counter(e["metadata_source_hint"] for e in still_entries)
    format_counts = Counter(e["image_format"] for e in still_entries)
    exif_orient_counts = Counter(str(e["exif_orientation_raw_tag"]) for e in still_entries)
    distinct_dims = len(
        {(e["oriented_width_px"], e["oriented_height_px"]) for e in still_entries if e["decode_status"] == "ok"}
    )

    redacted_summary: dict[str, Any] = {
        "schema": "scan-id-redacted-inventory-summary-v2",
        "generated_at_utc": now_iso,
        "pii_redacted": True,
        "filenames_or_hashes_included": False,
        "total_files_inspected": len(all_files),
        "file_extension_counts": dict(sorted(ext_counts.items())),
        "still_image_files": len(still_paths),
        "unique_still_images_by_sha256": len(still_entries),
        "byte_exact_duplicate_still_files": exact_duplicate_extra_files,
        "decodable_still_images": sum(e["decode_status"] == "ok" for e in still_entries),
        "undecodable_still_images": sum(e["decode_status"] != "ok" for e in still_entries),
        "distinct_oriented_dimensions": distinct_dims,
        "image_format_counts": dict(sorted(format_counts.items())),
        "raw_exif_orientation_tag_counts": dict(sorted(exif_orient_counts.items())),
        "images_with_capture_timestamp_exif": sum(e["has_capture_timestamp_exif"] for e in still_entries),
        "images_with_camera_model_exif": sum(e["has_camera_model_exif"] for e in still_entries),
        "metadata_source_hint_counts": dict(sorted(source_hint_counts.items())),
        "initial_suitability_counts": dict(sorted(suitability_counts.items())),
        "perceptual_near_duplicate_clusters": len(multi_clusters),
        "perceptual_near_duplicate_pairs": near_duplicate_pairs,
        "unique_visual_still_scenes_estimate": len(still_entries) - len(secondary_dups),
        "non_image_containers": {
            "videos": [
                {
                    "internal_code": v["internal_code"],
                    "decodable": v["decodable"],
                    "dimensions": f"{v['width_px']}x{v['height_px']}",
                    "frame_count": v["frame_count"],
                    "duration_sec": v["duration_sec"],
                    "still_images_matching_frames": v["still_images_matching_frames"],
                    "treated_as_independent_samples": False,
                }
                for v in video_reports
            ],
            "scanid_backups": [
                {
                    "internal_code": a["internal_code"],
                    "valid_header": a["valid_header"],
                    "asset_count": a["asset_count"],
                    "assets_byte_matching_still_images": a["assets_byte_matching_still_images"],
                    "unmatched_asset_count": a["unmatched_asset_count"],
                    "contains_crops_or_suggestions": a["contains_crops_or_suggestions"],
                    "treated_as_ground_truth": False,
                }
                for a in archive_reports
            ],
            "other_files": len(other_paths),
        },
        "human_annotation_progress": {
            "human_completed_images": 0,
            "second_reviewed_images": 0,
            "human_verified_documents": 0,
            "ai_suggestions_generated_separately": 0,
        },
        "independent_split_feasible_from_metadata": False,
        "independent_split_blockers": [
            "0/19 still images have EXIF capture timestamps or camera Make/Model provenance.",
            "Human independent primary annotation and second review have not been completed yet (0/19).",
            "Near-duplicate pair detected (IMG-01 and IMG-08, dHash64 Hamming=1) and 14/19 stills duplicate .scanid backup assets.",
        ],
    }

    private_inventory: dict[str, Any] = {
        "schema": "scan-id-private-local-inventory-v2",
        "generated_at_utc": now_iso,
        "warning": "PRIVATE LOCAL FILE — contains local relative paths and content hashes. Keep in ignored local-data/; never commit or upload.",
        "summary": redacted_summary,
        "still_images": still_entries,
        "videos": video_reports,
        "scanid_backups": archive_reports,
    }

    return private_inventory, seed_v2, redacted_summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, default=DEFAULT_INPUT_DIR)
    parser.add_argument("--inventory-out", type=Path, default=DEFAULT_INVENTORY_OUT)
    parser.add_argument("--seed-out", type=Path, default=DEFAULT_SEED_OUT)
    parser.add_argument("--redacted-summary-out", type=Path, default=DEFAULT_REDACTED_OUT)
    args = parser.parse_args()

    try:
        inv_out = _ensure_under_local_data(args.inventory_out)
        seed_out = _ensure_under_local_data(args.seed_out)
        red_out = _ensure_under_local_data(args.redacted_summary_out)

        private_inventory, seed_v2, redacted_summary = build_inventory(
            args.input_dir.resolve()
        )

        inv_out.parent.mkdir(parents=True, exist_ok=True)
        inv_out.write_text(json.dumps(private_inventory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        save_annotations(seed_v2, seed_out, require_complete=False)
        red_out.parent.mkdir(parents=True, exist_ok=True)
        red_out.write_text(json.dumps(redacted_summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

        print(json.dumps(redacted_summary, ensure_ascii=False, indent=2))
        print("Saved private inventory & unannotated v2 seed under ignored local-data/.")
        return 0
    except Exception as exc:
        print(f"FAIL: local inventory failed ({type(exc).__name__}): {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
