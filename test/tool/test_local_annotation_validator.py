from __future__ import annotations

import copy
import hashlib
import io
import json
import shutil
import struct
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from contextlib import redirect_stderr, redirect_stdout
from http.server import ThreadingHTTPServer
from io import StringIO
from pathlib import Path
from unittest.mock import patch

from PIL import Image, ImageDraw

from tool.create_local_evaluation_splits import SPLITS, create_splits
from tool.inventory_local_mostmskat import SCANID_MAGIC, build_inventory
from tool.serve_annotation_studio import StudioOnlyHandler
from tool.validate_local_annotations import (
    ANNOTATION_STATUS,
    BOUNDARY_STATUS,
    COORDINATE_SYSTEM,
    CROP_QUALITY,
    DIFFICULTY_FLAGS,
    EXCLUSION_REASONS,
    IMAGE_SOURCES,
    KINDS,
    SCHEMA,
    SUITABILITY_STATUS,
    ValidationError,
    build_dispute_queue,
    canonicalize_quad_clockwise_tl,
    compare,
    compute_dhash64_hex,
    display_click_to_normalized,
    load_and_validate,
    main,
    migrate_v1_to_v2,
    oriented_to_raw_normalized,
    polygon_iou,
    raw_to_oriented_normalized,
    save_annotations,
    validate_payload,
)

ROOT = Path(__file__).resolve().parents[2]
FULL_QUAD = [[0.1, 0.12], [0.88, 0.12], [0.88, 0.86], [0.1, 0.86]]


def make_distinct_dhash(index: int) -> str:
    """Generate pairwise far-apart 64-bit hex dHashes (Hamming >= 24) for distinct scenes."""
    # Reed-Muller / Walsh-Hadamard Walsh rows on 64 bits have pairwise Hamming distance 32!
    if index == 0:
        return "0" * 16
    mask = index & 0x3F
    if mask == 0:
        mask = 1
    bits = 0
    for pos in range(64):
        parity = (pos & mask).bit_count() & 1
        bits = (bits << 1) | parity
    return f"{bits:016x}"


def sample_fixture(
    idx: int = 1,
    *,
    annotator: str = "R1",
    group: str = "session-01",
    status: str = "second_review",
    kind: str = "unifiedNationalId",
    boundary_status: str = "complete",
    dhash_hex: str | None = None,
) -> dict:
    raw_id = hashlib.sha256(f"private-fixture-{idx}".encode("utf-8")).hexdigest()
    short = raw_id[:12]
    is_final = status in {"annotated", "second_review"}
    sr = (
        {
            "status": "agreed",
            "reviewer_id": "R2",
            "reviewed_at": "2026-10-26T14:00:00Z",
            "dispute_status": "none",
            "adjudicator_id": "",
            "adjudicated_at": "",
            "resolution_code": "",
        }
        if status == "second_review"
        else {
            "status": "not_started",
            "reviewer_id": "",
            "reviewed_at": "",
            "dispute_status": "none",
            "adjudicator_id": "",
            "adjudicated_at": "",
            "resolution_code": "",
        }
    )
    corners = copy.deepcopy(FULL_QUAD) if boundary_status == "complete" else None
    poly = (
        copy.deepcopy(FULL_QUAD)
        if boundary_status == "complete"
        else ([[0.1, 0.1], [0.8, 0.1], [0.8, 0.7], [0.1, 0.7]] if boundary_status != "undeterminable" else [])
    )
    return {
        "image_id": raw_id,
        "internal_code": f"IMG-{idx:02d}",
        "image_format": "jpeg",
        "decode_status": "ok",
        "raw_width_px": 1000,
        "raw_height_px": 800,
        "exif_orientation": 1,
        "width_px": 1000,
        "height_px": 800,
        "perceptual_dhash64": dhash_hex if dhash_hex is not None else make_distinct_dhash(idx),
        "near_duplicate_cluster_id": "",
        "image_source": "camera_photo",
        "capture_group_id": group,
        "suitability_status": "annotatable",
        "annotation_status": status,
        "exclusion_reason": "",
        "image_quality_level": "good",
        "difficulty_reasons": [],
        "annotator_id": annotator if is_final else "",
        "annotated_at": "2026-10-26T12:00:00Z" if is_final else "",
        "second_review": sr,
        "no_document": False,
        "document_count": 1,
        "documents": [
            {
                "document_id": f"{short}-doc-01",
                "label_origin": "human_manual",
                "human_verified": is_final,
                "document_kind": kind,
                "boundary_status": boundary_status,
                "corners": corners,
                "visible_polygon": poly,
                "crop_quality": "acceptable",
                "quality_flags": [],
            }
        ],
        "ai_suggestions": [],
    }


def annotation_payload(annotator: str = "ADJ1", samples: list[dict] | None = None) -> dict:
    return {
        "schema": SCHEMA,
        "schema_version": "2.0.0",
        "annotator_id": annotator,
        "created_at": "2026-10-26T12:00:00Z",
        "coordinate_system": COORDINATE_SYSTEM,
        "exif_policy": "apply EXIF orientation (tag 274) before display and measurement; coordinates normalized to [0, 1]",
        "pii_policy": "boundary and document-kind labels only; never store personal names, ID numbers, filenames, or OCR text",
        "samples": samples if samples is not None else [sample_fixture(1, annotator="R1")],
    }


class LocalAnnotationValidatorV2Test(unittest.TestCase):
    def load_payload(self, payload: dict, *, complete: bool = True, images_dir: Path | None = None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "annotations.json"
            path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            return load_and_validate(path, require_complete=complete, images_dir=images_dir)

    # 1. Schema & Version Integrity + JSON Schema Alignment
    def test_json_schema_file_matches_validator_enums(self):
        schema_path = ROOT / "tool" / "schemas" / "local_reference_dataset_v2.schema.json"
        self.assertTrue(schema_path.is_file())
        schema_doc = json.loads(schema_path.read_text(encoding="utf-8"))
        self.assertEqual(schema_doc["properties"]["schema"]["const"], SCHEMA)
        self.assertEqual(schema_doc["properties"]["coordinate_system"]["const"], COORDINATE_SYSTEM)
        defs = schema_doc["$defs"]
        self.assertEqual(set(defs["difficultyFlag"]["enum"]), DIFFICULTY_FLAGS)
        self.assertEqual(set(defs["documentAnnotation"]["properties"]["document_kind"]["enum"]), KINDS)
        self.assertEqual(set(defs["documentAnnotation"]["properties"]["boundary_status"]["enum"]), BOUNDARY_STATUS)
        self.assertEqual(set(defs["documentAnnotation"]["properties"]["crop_quality"]["enum"]), CROP_QUALITY)
        sample_props = defs["sample"]["properties"]
        self.assertEqual(set(sample_props["image_source"]["enum"]), IMAGE_SOURCES)
        self.assertEqual(set(sample_props["suitability_status"]["enum"]), SUITABILITY_STATUS)
        self.assertEqual(set(sample_props["annotation_status"]["enum"]), ANNOTATION_STATUS)
        self.assertEqual(set(sample_props["exclusion_reason"]["enum"]), EXCLUSION_REASONS)

    def test_rejects_invalid_schema_or_version(self):
        for bad_field, bad_val in (
            ("schema", "scan-id-local-annotations-v99"),
            ("schema_version", "1.0.0"),
            ("schema_version", "invalid"),
            ("coordinate_system", "raw_pixels"),
        ):
            payload = annotation_payload()
            payload[bad_field] = bad_val
            with self.assertRaises(ValidationError):
                self.load_payload(payload, complete=False)

    def test_rejects_forbidden_pii_path_and_ocr_fields(self):
        for forbidden_key in ("filename", "source_path", "full_name", "id_number", "ocr_reference_text"):
            payload = annotation_payload()
            payload["samples"][0][forbidden_key] = "sensitive-value"
            with self.assertRaisesRegex(ValidationError, "forbidden PII/source-path/text"):
                self.load_payload(payload, complete=False)

    def test_cli_redacts_annotator_codes_and_image_ids(self):
        payload = annotation_payload("reviewer-secret-01")
        image_id = payload["samples"][0]["image_id"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private-annotations.json"
            path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            output = StringIO()
            with patch("sys.argv", ["validate_local_annotations", str(path)]), redirect_stdout(output):
                self.assertEqual(main(), 0)
        text = output.getvalue()
        self.assertIn("annotator code accepted (redacted)", text)
        self.assertNotIn("reviewer-secret-01", text)
        self.assertNotIn(image_id, text)

    def test_v1_migration_strips_ocr_text_and_validates_as_v2(self):
        v1 = {
            "schema": "scan-id-local-annotations-v1",
            "reviewer_id": "R1",
            "created_at": "2026-10-26T10:00:00Z",
            "samples": [
                {
                    "sample_id": hashlib.sha256(b"legacy-1").hexdigest(),
                    "width_px": 900,
                    "height_px": 600,
                    "decode_status": "ok",
                    "capture_group_id": "grp-1",
                    "review_status": "reviewed",
                    "adjudication_status": "adjudicated",
                    "no_document": False,
                    "document_count": 1,
                    "documents": [
                        {
                            "document_kind": "residenceCard",
                            "visibility": "fully_visible",
                            "crop_quality": "acceptable",
                            "quality_flags": ["perspective", "glare"],
                            "visible_polygon": copy.deepcopy(FULL_QUAD),
                            "quadrilateral": copy.deepcopy(FULL_QUAD),
                            "ocr_reference_text": "نص شخصي قديم",
                            "ocr_reference_verified": True,
                        }
                    ],
                }
            ],
        }
        migrated = migrate_v1_to_v2(v1)
        self.assertNotIn("نص شخصي قديم", json.dumps(migrated, ensure_ascii=False))
        _, summary = validate_payload(migrated, require_complete=True)
        self.assertEqual(summary["scorable_four_corner_documents"], 1)

    # 2. On-Disk Image Existence, Decode Integrity & EXIF Orientation Check
    def test_verifies_referenced_images_exist_decode_and_match_exif(self):
        with tempfile.TemporaryDirectory() as directory:
            img_dir = Path(directory) / "imgs"
            img_dir.mkdir()

            # Create asymmetric 400x240 image with EXIF Orientation=6 (rotates to 240x400)
            raw_im = Image.new("RGB", (400, 240), color=(30, 60, 90))
            draw = ImageDraw.Draw(raw_im)
            draw.rectangle([40, 30, 340, 200], fill=(220, 210, 180))
            exif = Image.Exif()
            exif[274] = 6  # Rotate 90 CW -> oriented is 240x400
            valid_path = img_dir / "cam_exif6.jpg"
            raw_im.save(valid_path, format="JPEG", exif=exif.tobytes())
            valid_sha = hashlib.sha256(valid_path.read_bytes()).hexdigest()
            with Image.open(valid_path) as check_im:
                valid_dhash = compute_dhash64_hex(check_im)

            # Also create a corrupt image file properly marked decode_status=failed
            corrupt_path = img_dir / "broken.jpg"
            corrupt_path.write_bytes(b"\xff\xd8\xff\xe0corrupt-not-a-valid-jpeg")
            corrupt_sha = hashlib.sha256(corrupt_path.read_bytes()).hexdigest()

            s_ok = sample_fixture(1)
            s_ok["image_id"] = valid_sha
            s_ok["raw_width_px"] = 400
            s_ok["raw_height_px"] = 240
            s_ok["exif_orientation"] = 6
            s_ok["width_px"] = 240
            s_ok["height_px"] = 400
            s_ok["perceptual_dhash64"] = valid_dhash

            s_bad_file = sample_fixture(2)
            s_bad_file["image_id"] = corrupt_sha
            s_bad_file["image_format"] = "unknown"
            s_bad_file["decode_status"] = "failed"
            s_bad_file["raw_width_px"] = 0
            s_bad_file["raw_height_px"] = 0
            s_bad_file["exif_orientation"] = 0
            s_bad_file["width_px"] = 0
            s_bad_file["height_px"] = 0
            s_bad_file["perceptual_dhash64"] = ""
            s_bad_file["suitability_status"] = "unreadable"
            s_bad_file["annotation_status"] = "excluded"
            s_bad_file["exclusion_reason"] = "decode_failed"
            s_bad_file["annotator_id"] = ""
            s_bad_file["annotated_at"] = ""
            s_bad_file["second_review"] = {
                "status": "not_started",
                "reviewer_id": "",
                "reviewed_at": "",
                "dispute_status": "none",
                "adjudicator_id": "",
                "adjudicated_at": "",
                "resolution_code": "",
            }
            s_bad_file["no_document"] = True
            s_bad_file["document_count"] = 0
            s_bad_file["documents"] = []

            payload = annotation_payload(samples=[s_ok, s_bad_file])
            _, summary = self.load_payload(payload, complete=True, images_dir=img_dir)
            self.assertEqual(summary["image_verification"]["verified_decoded_ok"], 1)
            self.assertEqual(summary["image_verification"]["verified_decode_failed"], 1)

            # Missing image on disk must fail
            missing_payload = annotation_payload(samples=[sample_fixture(99)])
            with self.assertRaisesRegex(ValidationError, "not found in the local images directory"):
                self.load_payload(missing_payload, complete=False, images_dir=img_dir)

            # Corrupt file falsely claiming decode_status='ok' must fail
            false_ok = copy.deepcopy(s_ok)
            false_ok["image_id"] = corrupt_sha
            with self.assertRaisesRegex(ValidationError, "failed image decoding on disk"):
                self.load_payload(annotation_payload(samples=[false_ok]), complete=False, images_dir=img_dir)

    # 3. Duplicate Image IDs & Document IDs
    def test_rejects_duplicate_image_ids_and_document_ids(self):
        s1 = sample_fixture(1)
        s2 = copy.deepcopy(s1)
        s2["internal_code"] = "IMG-02"
        s2["documents"][0]["document_id"] = "unique-doc-02"
        with self.assertRaisesRegex(ValidationError, "duplicates an image_id"):
            self.load_payload(annotation_payload(samples=[s1, s2]), complete=False)

        s3 = sample_fixture(3)
        s3["documents"][0]["document_id"] = s1["documents"][0]["document_id"]
        with self.assertRaisesRegex(ValidationError, "duplicates a document_id"):
            self.load_payload(annotation_payload(samples=[s1, s3]), complete=False)

    # 4. Coordinate Bounds & EXIF Bijection Math
    def test_rejects_out_of_bounds_or_non_numeric_coordinates(self):
        for bad_pt in ([-0.01, 0.2], [0.2, 1.05], [True, 0.2], ["0.2", 0.2], [0.2]):
            payload = annotation_payload()
            quad = copy.deepcopy(FULL_QUAD)
            quad[0] = bad_pt
            payload["samples"][0]["documents"][0]["corners"] = quad
            payload["samples"][0]["documents"][0]["visible_polygon"] = quad
            with self.assertRaises(ValidationError):
                self.load_payload(payload, complete=False)

    def test_exif_coordinate_bijections_for_all_orientations(self):
        test_pts = [(0.15, 0.25), (0.82, 0.19), (0.77, 0.91), (0.04, 0.68)]
        for orient in range(0, 9):
            for xr, yr in test_pts:
                xo, yo = raw_to_oriented_normalized(xr, yr, orient)
                self.assertTrue(0.0 <= xo <= 1.0 and 0.0 <= yo <= 1.0)
                back_x, back_y = oriented_to_raw_normalized(xo, yo, orient)
                self.assertAlmostEqual(xr, back_x, places=9)
                self.assertAlmostEqual(yr, back_y, places=9)

        nx, ny = display_click_to_normalized(
            250.0, 190.0, pan_x=50.0, pan_y=40.0, zoom=2.0, canvas_width=400.0, canvas_height=300.0
        )
        self.assertAlmostEqual(nx, 0.25, places=6)
        self.assertAlmostEqual(ny, 0.25, places=6)

    # 5 & 6. Corner Ordering, Self-Intersection, Convexity & Positive Area
    def test_rejects_ccw_wrong_start_corner_self_intersecting_and_zero_area(self):
        # Counter-clockwise
        ccw = [[0.1, 0.1], [0.1, 0.9], [0.9, 0.9], [0.9, 0.1]]
        p = annotation_payload()
        p["samples"][0]["documents"][0]["corners"] = ccw
        p["samples"][0]["documents"][0]["visible_polygon"] = ccw
        with self.assertRaisesRegex(ValidationError, "clockwise"):
            self.load_payload(p, complete=False)

        # Clockwise but starting at TR instead of TL
        wrong_start = [[0.88, 0.12], [0.88, 0.86], [0.1, 0.86], [0.1, 0.12]]
        p = annotation_payload()
        p["samples"][0]["documents"][0]["corners"] = wrong_start
        p["samples"][0]["documents"][0]["visible_polygon"] = wrong_start
        with self.assertRaisesRegex(ValidationError, "top-left"):
            self.load_payload(p, complete=False)

        # Canonicalizer fixes scrambled order
        scrambled = [(0.88, 0.86), (0.1, 0.12), (0.88, 0.12), (0.1, 0.86)]
        canon = [[x, y] for x, y in canonicalize_quad_clockwise_tl(scrambled)]
        self.assertEqual(canon, FULL_QUAD)

        # Self-intersecting bowtie
        crossed = [[0.1, 0.1], [0.9, 0.9], [0.9, 0.1], [0.1, 0.9]]
        p = annotation_payload()
        p["samples"][0]["documents"][0]["corners"] = crossed
        p["samples"][0]["documents"][0]["visible_polygon"] = crossed
        with self.assertRaisesRegex(ValidationError, "self-intersects"):
            self.load_payload(p, complete=False)

        # Collinear / near-zero area sliver
        sliver = [[0.1, 0.1], [0.5, 0.1], [0.9, 0.10001], [0.2, 0.10001]]
        p = annotation_payload()
        p["samples"][0]["documents"][0]["corners"] = sliver
        p["samples"][0]["documents"][0]["visible_polygon"] = sliver
        with self.assertRaisesRegex(ValidationError, "zero or near-zero area"):
            self.load_payload(p, complete=False)

    # 7. Duplicate or Very-Close Vertices
    def test_rejects_duplicate_and_near_duplicate_vertices(self):
        dup = [[0.1, 0.1], [0.1, 0.1], [0.9, 0.9], [0.1, 0.9]]
        p = annotation_payload()
        p["samples"][0]["documents"][0]["corners"] = dup
        p["samples"][0]["documents"][0]["visible_polygon"] = dup
        with self.assertRaisesRegex(ValidationError, "duplicate vertices"):
            self.load_payload(p, complete=False)

        too_close = [[0.1, 0.1], [0.102, 0.101], [0.9, 0.9], [0.1, 0.9]]
        p = annotation_payload()
        p["samples"][0]["documents"][0]["corners"] = too_close
        p["samples"][0]["documents"][0]["visible_polygon"] = too_close
        with self.assertRaisesRegex(ValidationError, "too close"):
            self.load_payload(p, complete=False)

    # 8 & 9. Document Counts & Unscorable Exclusion from Boundary Evaluation
    def test_document_count_rules_and_unscorable_excluded_not_counted_as_boundary_samples(self):
        # Count mismatch rejected
        bad_count = annotation_payload()
        bad_count["samples"][0]["document_count"] = 2
        with self.assertRaisesRegex(ValidationError, "document_count"):
            self.load_payload(bad_count, complete=False)

        # Undeterminable document claiming corners is rejected
        bad_undet = annotation_payload()
        bad_undet["samples"][0]["documents"][0]["boundary_status"] = "undeterminable"
        with self.assertRaisesRegex(ValidationError, "undeterminable must have corners=null"):
            self.load_payload(bad_undet, complete=False)

        # Valid mix: 1 scorable complete, 1 occluded visible-only, 1 undeterminable, 1 excluded image
        s_complete = sample_fixture(1, group="g1")
        s_occluded = sample_fixture(2, group="g2", boundary_status="occluded")
        s_undet = sample_fixture(3, group="g3", boundary_status="undeterminable")
        s_excluded = sample_fixture(4, group="", status="excluded")
        s_excluded["exclusion_reason"] = "synthetic_or_promotional_mockup"
        s_excluded["no_document"] = True
        s_excluded["document_count"] = 0
        s_excluded["documents"] = []

        _, summary = self.load_payload(
            annotation_payload(samples=[s_complete, s_occluded, s_undet, s_excluded]),
            complete=True,
        )
        self.assertEqual(summary["samples"], 4)
        self.assertEqual(summary["scorable_boundary_samples"], 2)
        self.assertEqual(summary["scorable_four_corner_documents"], 1)
        self.assertEqual(summary["scorable_visible_polygon_documents"], 2)
        self.assertEqual(summary["unscorable_boundary_documents"], 1)

    # 10. Strict Separation Between Machine Suggestions and Human Ground Truth
    def test_rejects_machine_suggestions_mixed_into_human_documents(self):
        # Forged label_origin inside documents
        p = annotation_payload()
        p["samples"][0]["documents"][0]["label_origin"] = "frozen_ai_hybrid"
        with self.assertRaisesRegex(ValidationError, "machine suggestions or legacy crops"):
            self.load_payload(p, complete=False)

        # Copied suggestion without human_verified=True in annotated sample
        p2 = annotation_payload()
        p2["samples"][0]["documents"][0]["label_origin"] = "human_verified_from_suggestion"
        p2["samples"][0]["documents"][0]["human_verified"] = False
        with self.assertRaisesRegex(ValidationError, "human_verified=true"):
            self.load_payload(p2, complete=False)

        # Unannotated sample with ai_suggestions stays 0 human docs & 0 scorable samples
        s_seed = sample_fixture(1, status="unannotated")
        s_seed["no_document"] = False
        s_seed["document_count"] = 0
        s_seed["documents"] = []
        s_seed["ai_suggestions"] = [
            {
                "suggestion_id": "seed-ai-01",
                "proposal_source": "frozen_ai_hybrid",
                "corners": copy.deepcopy(FULL_QUAD),
                "confidence": 0.72,
                "gate_verdict": "needsReview",
            }
        ]
        _, summary = self.load_payload(annotation_payload("SEED_UNANNOTATED", [s_seed]), complete=False)
        self.assertEqual(summary["ai_suggestions"], 1)
        self.assertEqual(summary["human_verified_documents"], 0)
        self.assertEqual(summary["scorable_boundary_samples"], 0)

    # 6 (cont). Blind Reviewer Comparison & Dispute Queue Without Auto-Averaging
    def test_blind_comparison_and_dispute_queue_never_auto_average(self):
        left = annotation_payload("R1", [sample_fixture(1, annotator="R1", status="annotated")])
        right_sample = sample_fixture(1, annotator="R2", status="annotated", kind="passport")
        shifted = [[0.14, 0.12], [0.91, 0.12], [0.91, 0.86], [0.14, 0.86]]
        right_sample["documents"][0]["corners"] = shifted
        right_sample["documents"][0]["visible_polygon"] = shifted
        right = annotation_payload("R2", [right_sample])

        metrics = compare(left, right, 0.95)
        self.assertEqual(metrics["kind_disagreements"], 1)
        self.assertEqual(metrics["polygon_iou_below_threshold"], 1)
        self.assertEqual(metrics["disputed_sample_count"], 1)
        self.assertFalse(metrics["auto_merged_or_averaged"])

        queue = build_dispute_queue(left, right, 0.95)
        self.assertFalse(queue["auto_resolution_applied"])
        self.assertEqual(queue["items"][0]["dispute_status"], "open_dispute")

    # 11. Data Leakage Prevention Across Train / Validation / Test Splits
    def test_split_creation_enforces_group_cluster_dhash_and_statistical_minimums(self):
        samples = []
        # 1 train group (2 docs), 1 val group (2 docs), 3 test groups (4 docs each = 12 test docs)
        idx = 1
        for grp, n_docs in (("train-g1", 2), ("val-g1", 2), ("test-g1", 4), ("test-g2", 4), ("test-g3", 4)):
            for _ in range(n_docs):
                samples.append(sample_fixture(idx, group=grp))
                idx += 1

        payload = annotation_payload("ADJ1", samples)
        assignments = {
            "train": {"train-g1"},
            "validation": {"val-g1"},
            "test": {"test-g1", "test-g2", "test-g3"},
        }
        with tempfile.TemporaryDirectory() as directory:
            ann_path = Path(directory) / "adj.json"
            ann_path.write_text(json.dumps(payload), encoding="utf-8")
            validated, _ = load_and_validate(ann_path, require_complete=True)
            splits, summary = create_splits(validated, assignments, ann_path)
            self.assertEqual(summary["test"]["capture_groups"], 3)
            self.assertEqual(summary["test"]["scorable_boundary_documents"], 12)
            self.assertTrue(splits["threshold_tuning_on_test_forbidden"])
            self.assertEqual(len(splits["locked_test_manifest"]), 12)

            # Near-duplicate dHash leakage between train and test (Hamming=1) must fail!
            leaked = copy.deepcopy(validated)
            train_dhash = leaked["samples"][0]["perceptual_dhash64"]
            # Flip 1 bit of train_dhash and place it in test-g1
            flipped_int = int(train_dhash, 16) ^ 0x1
            leaked["samples"][-1]["perceptual_dhash64"] = f"{flipped_int:016x}"
            with self.assertRaisesRegex(ValidationError, "cross-split near-duplicate detected"):
                create_splits(leaked, assignments, ann_path)

            # Shared near_duplicate_cluster_id across train and validation must fail!
            cluster_leak = copy.deepcopy(validated)
            cluster_leak["samples"][0]["near_duplicate_cluster_id"] = "dup-cluster-01"
            cluster_leak["samples"][2]["near_duplicate_cluster_id"] = "dup-cluster-01"
            with self.assertRaisesRegex(ValidationError, "near_duplicate_cluster_id"):
                create_splits(cluster_leak, assignments, ann_path)

            # Statistically tiny 1-group test split must be rejected by default!
            tiny_samples = [
                sample_fixture(1, group="tr"),
                sample_fixture(2, group="va"),
                sample_fixture(3, group="te"),
            ]
            tiny_payload = annotation_payload("ADJ1", tiny_samples)
            tiny_path = Path(directory) / "tiny.json"
            tiny_path.write_text(json.dumps(tiny_payload), encoding="utf-8")
            tiny_val, _ = load_and_validate(tiny_path, require_complete=True)
            with self.assertRaisesRegex(ValidationError, "independent capture group"):
                create_splits(
                    tiny_val,
                    {"train": {"tr"}, "validation": {"va"}, "test": {"te"}},
                    tiny_path,
                )

    # 12. Lossless Save & Reload + Inventory & Studio Server Verification
    def test_lossless_save_and_reload_preserves_all_fields(self):
        s1 = sample_fixture(1, group="g1")
        s1["difficulty_reasons"] = ["glare", "laminated_outer_pouch"]
        s1["documents"][0]["quality_flags"] = ["glare", "laminated_outer_pouch"]
        s2 = sample_fixture(2, group="g2", boundary_status="occluded")
        s2["documents"][0]["visible_polygon"] = [[0.1, 0.1], [0.9, 0.1], [0.9, 0.5], [0.45, 0.5], [0.45, 0.9], [0.1, 0.9]]
        s2["difficulty_reasons"] = ["occlusion"]
        s3 = sample_fixture(3, group="g3")
        s3["no_document"] = True
        s3["document_count"] = 0
        s3["documents"] = []
        payload = annotation_payload("ADJ1", [s1, s2, s3])

        with tempfile.TemporaryDirectory() as directory:
            out_path = Path(directory) / "roundtrip.json"
            reloaded, summary = save_annotations(
                payload,
                out_path,
                require_complete=True,
                allow_outside_local_data_in_tests=True,
            )
            self.assertEqual(reloaded, payload)
            self.assertEqual(summary["background_images"], 1)
            self.assertAlmostEqual(
                polygon_iou(
                    [tuple(pt) for pt in s2["documents"][0]["visible_polygon"]],
                    [tuple(pt) for pt in reloaded["samples"][1]["documents"][0]["visible_polygon"]],
                ),
                1.0,
                places=9,
            )

    def test_inventory_builder_detects_near_duplicates_scanid_overlap_and_redacts_pii(self):
        with tempfile.TemporaryDirectory() as directory:
            corpus = Path(directory) / "corpus"
            corpus.mkdir()

            # Image A (original) + Image B (resized screenshot near-duplicate of A)
            im_a = Image.new("RGB", (600, 400), color=(240, 210, 40))
            d = ImageDraw.Draw(im_a)
            d.rectangle([120, 80, 480, 320], fill=(20, 110, 70))
            d.ellipse([240, 140, 360, 260], fill=(245, 245, 245))
            path_a = corpus / "secret_person_name_01.jpg"
            im_a.save(path_a, format="JPEG", quality=92)

            im_b = im_a.resize((540, 360), Image.Resampling.BILINEAR)
            path_b = corpus / "Screenshot_2026_secret_02.jpg"
            im_b.save(path_b, format="JPEG", quality=85)

            # Fake .scanid backup referencing Image A's exact SHA-256
            sha_a = hashlib.sha256(path_a.read_bytes()).hexdigest()
            manifest_bytes = json.dumps(
                {
                    "format": 1,
                    "project": {
                        "assets": [
                            {
                                "originalPath": "projects/p1/orig.jpg",
                                "suggestedCrop": {"corners": FULL_QUAD},
                            }
                        ]
                    },
                    "files": [
                        {
                            "path": "projects/p1/orig.jpg",
                            "size": path_a.stat().st_size,
                            "sha256": sha_a,
                        }
                    ],
                }
            ).encode("utf-8")
            backup_path = corpus / "backup.scanid"
            backup_path.write_bytes(
                SCANID_MAGIC + struct.pack(">I", len(manifest_bytes)) + manifest_bytes
            )

            private_inv, seed_v2, redacted = build_inventory(corpus, include_ai_suggestions=False)
            self.assertEqual(redacted["total_files_inspected"], 3)
            self.assertEqual(redacted["decodable_still_images"], 2)
            self.assertEqual(redacted["perceptual_near_duplicate_clusters"], 1)
            self.assertEqual(redacted["unique_visual_still_scenes_estimate"], 1)
            self.assertEqual(
                redacted["non_image_containers"]["scanid_backups"][0]["assets_byte_matching_still_images"],
                1,
            )
            self.assertFalse(
                redacted["non_image_containers"]["scanid_backups"][0]["treated_as_ground_truth"]
            )
            # Redacted summary must NEVER leak filenames or content hashes
            redacted_json = json.dumps(redacted)
            self.assertNotIn("secret_person_name", redacted_json)
            self.assertNotIn(sha_a, redacted_json)

            # Seed v2 must validate cleanly including on-disk image verification
            _, seed_counts = validate_payload(seed_v2, require_complete=False, images_dir=corpus)
            self.assertEqual(seed_counts["samples"], 2)
            self.assertEqual(seed_counts["human_completed_images"], 0)

    def test_studio_server_exposes_only_studio_html_and_blocks_private_dirs(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), StudioOnlyHandler)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=5) as resp:
                self.assertEqual(resp.status, 200)
                self.assertEqual(resp.headers.get("Content-Security-Policy", "").count("connect-src 'none'"), 1)
                body = resp.read().decode("utf-8")
                self.assertIn("scan-id-local-annotations-v2", body)
                self.assertIn('id="imageFiles" type="file"', body)
                self.assertIn('multiple>', body)
                self.assertIn("imageOrientation: 'from-image'", body)
                self.assertIn("adb reverse tcp:8080 tcp:8080", body)
            req = urllib.request.Request(f"http://127.0.0.1:{port}/", data=b"private", method="POST")
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(req, timeout=5)
            self.assertEqual(ctx.exception.code, 405)
            self.assertEqual(ctx.exception.headers.get("Allow"), "GET, HEAD")
            ctx.exception.close()
            for blocked in ("/Mostmskat/test.jpg", "/local-data/secret.json", "/README.md"):
                with self.assertRaises(urllib.error.HTTPError) as ctx:
                    urllib.request.urlopen(f"http://127.0.0.1:{port}{blocked}", timeout=5)
                self.assertEqual(ctx.exception.code, 404)
                ctx.exception.close()
        finally:
            server.shutdown()
            server.server_close()

    def test_cli_compare_returns_exit_2_on_disagreement_and_guards_dispute_output_path(self):
        left = annotation_payload("R1", [sample_fixture(1, annotator="R1", status="annotated")])
        right = annotation_payload("R2", [sample_fixture(1, annotator="R2", status="annotated", kind="passport")])
        with tempfile.TemporaryDirectory() as directory:
            left_path = Path(directory) / "r1.json"
            right_path = Path(directory) / "r2.json"
            left_path.write_text(json.dumps(left), encoding="utf-8")
            right_path.write_text(json.dumps(right), encoding="utf-8")
            out_buf, err_buf = StringIO(), StringIO()
            with (
                patch(
                    "sys.argv",
                    [
                        "validate_local_annotations",
                        str(left_path),
                        "--compare",
                        str(right_path),
                        "--polygon-iou-review-threshold",
                        "0.90",
                    ],
                ),
                redirect_stdout(out_buf),
                redirect_stderr(err_buf),
            ):
                self.assertEqual(main(), 2)
            self.assertIn("REVIEW REQUIRED", err_buf.getvalue())

            # Writing dispute queue inside repo outside local-data/ must fail (exit 1)
            forbidden_repo_path = ROOT / "docs" / "disputes-forbidden.json"
            out_buf2, err_buf2 = StringIO(), StringIO()
            with (
                patch(
                    "sys.argv",
                    [
                        "validate_local_annotations",
                        str(left_path),
                        "--compare",
                        str(right_path),
                        "--polygon-iou-review-threshold",
                        "0.90",
                        "--write-disputes",
                        str(forbidden_repo_path),
                    ],
                ),
                redirect_stdout(out_buf2),
                redirect_stderr(err_buf2),
            ):
                self.assertEqual(main(), 1)
            self.assertFalse(forbidden_repo_path.exists())

    def test_require_complete_rejects_open_dispute_unannotated_and_unreviewed_hard_cases(self):
        # Unannotated rejected under require_complete
        unann = annotation_payload("ADJ1", [sample_fixture(1, status="unannotated")])
        unann["samples"][0]["document_count"] = 0
        unann["samples"][0]["documents"] = []
        with self.assertRaisesRegex(ValidationError, "incomplete annotation_status"):
            self.load_payload(unann, complete=True)

        # Hard case (glare) with only primary review (second_review.status == 'not_started') rejected
        hard_primary_only = sample_fixture(1, annotator="R1", status="annotated")
        hard_primary_only["difficulty_reasons"] = ["glare"]
        with self.assertRaisesRegex(ValidationError, "requires completed second_review"):
            self.load_payload(annotation_payload("ADJ1", [hard_primary_only]), complete=True)

        # Open dispute rejected under require_complete
        disputed = sample_fixture(1, annotator="R1", status="annotated")
        disputed["second_review"] = {
            "status": "disputed",
            "reviewer_id": "R2",
            "reviewed_at": "2026-10-26T15:00:00Z",
            "dispute_status": "open_dispute",
            "adjudicator_id": "",
            "adjudicated_at": "",
            "resolution_code": "",
        }
        with self.assertRaisesRegex(ValidationError, "unresolved reviewer dispute"):
            self.load_payload(annotation_payload("ADJ1", [disputed]), complete=True)

    @unittest.skipUnless(shutil.which("node"), "node is required for studio JS execution test")
    def test_studio_javascript_geometry_exif_and_v1_upgrade_match_python_validator(self):
        html_source = (ROOT / "tool" / "local_annotation_studio.html").read_text(encoding="utf-8")
        js_code = html_source.split("<script>", 1)[1].split("</script>", 1)[0]

        # Build a tiny real EXIF=6 JPEG buffer to verify JS EXIF & raw dimension parser
        im = Image.new("RGB", (320, 180), color=(50, 90, 130))
        exif = Image.Exif()
        exif[274] = 6
        buf = io.BytesIO()
        im.save(buf, format="JPEG", exif=exif.tobytes())
        jpeg_hex = buf.getvalue().hex()
        js_roundtrip_sample = sample_fixture(93, annotator="R1", status="second_review")
        js_roundtrip_sample["ai_suggestions"] = [{
            "suggestion_id": "fixture-ai-01",
            "proposal_source": "frozen_ai_hybrid",
            "corners": copy.deepcopy(FULL_QUAD),
            "region_bbox": [0.1, 0.12, 0.88, 0.86],
            "confidence": 0.73,
            "gate_verdict": "needsReview",
        }]
        js_roundtrip_json = json.dumps(js_roundtrip_sample, separators=(",", ":"))

        harness = f"""
const noop = () => ({{
  addEventListener: () => {{}},
  classList: {{ add: () => {{}}, remove: () => {{}}, toggle: () => {{}} }},
  querySelectorAll: () => [],
  replaceChildren: () => {{}},
  getContext: () => ({{ clearRect: () => {{}}, drawImage: () => {{}} }}),
  style: {{}},
  value: '',
  checked: true
}});
globalThis.__SCAN_ID_TEST_HOOK__ = true;
globalThis.window = {{ addEventListener: () => {{}} }};
globalThis.document = {{ getElementById: noop, createElement: noop, body: {{ appendChild: () => {{}} }} }};
globalThis.localStorage = {{ getItem: () => null, setItem: () => {{}}, removeItem: () => {{}} }};
{js_code}
const api = globalThis.__SCAN_ID_TEST_EXPORTS__;
const bytes = Uint8Array.from(Buffer.from("{jpeg_hex}", "hex"));
const exifMeta = api.parseJpegExifAndRawSize(bytes);
const canon = api.canonicalizeQuadClockwiseTL([[0.88, 0.86], [0.1, 0.12], [0.88, 0.12], [0.1, 0.86]]);
const okCheck = api.inspectDocumentGeometry(
  {{ boundary_status: "complete", visible_polygon: canon }},
  {{ width_px: 1000, height_px: 800 }}
);
const crossedCheck = api.inspectDocumentGeometry(
  {{ boundary_status: "complete", visible_polygon: [[0.1,0.1],[0.9,0.9],[0.9,0.1],[0.1,0.9]] }},
  {{ width_px: 1000, height_px: 800 }}
);
const coords = api.clientPointToNormalized(620, 460, {{left:100,top:50}}, 20, 10, 2, 1000, 500);
const shaEmpty = api.sha256HexFallback(new ArrayBuffer(0));
const shaAbc = api.sha256HexFallback(Buffer.from("abc"));
api.appState.samples = [{js_roundtrip_json}];
const exported = api.buildExportPayload("R1");
api.restoreFromPayloadObject(exported);
const reexported = api.buildExportPayload("R1");
const upgraded = api.upgradeLegacyV1InBrowser({{
  schema: "scan-id-local-annotations-v1",
  reviewer_id: "R1",
  created_at: "2026-10-26T12:00:00Z",
  samples: [{{
    sample_id: "{"a" * 64}",
    width_px: 800,
    height_px: 600,
    decode_status: "ok",
    capture_group_id: "grp-js",
    review_status: "reviewed",
    adjudication_status: "not_adjudicated",
    no_document: false,
    documents: [{{
      document_kind: "unifiedNationalId",
      visibility: "fully_visible",
      crop_quality: "acceptable",
      quality_flags: ["glare"],
      visible_polygon: canon
    }}]
  }}]
}});
console.log(JSON.stringify({{ exifMeta, canon, okCheck, crossedCheck, upgraded, coords, shaEmpty, shaAbc, exported, reexported, ham: api.dhashHamming("0000000000000000", "0000000000000003") }}));
"""
        proc = subprocess.run(["node", "-e", harness], check=True, capture_output=True, text=True)
        out = json.loads(proc.stdout.strip())
        self.assertEqual(out["exifMeta"], {"format": "jpeg", "exifOrientation": 6, "rawWidth": 320, "rawHeight": 180})
        self.assertEqual(out["canon"], FULL_QUAD)
        self.assertEqual(out["okCheck"]["level"], "ok")
        self.assertEqual(out["crossedCheck"]["level"], "err")
        self.assertEqual(out["ham"], 2)
        self.assertEqual(out["coords"], {"vx": 520, "vy": 410, "nx": 0.25, "ny": 0.4})
        self.assertEqual(out["shaEmpty"], hashlib.sha256(b"").hexdigest())
        self.assertEqual(out["shaAbc"], hashlib.sha256(b"abc").hexdigest())
        self.assertEqual(out["exported"]["schema_version"], "2.0.0")
        self.assertEqual(out["exported"]["samples"], out["reexported"]["samples"])
        self.assertEqual(out["exported"]["samples"][0]["ai_suggestions"][0]["region_bbox"], [0.1, 0.12, 0.88, 0.86])
        self.assertNotIn("fixture-ai-01", json.dumps(out["exported"]["samples"][0]["documents"]))
        _, roundtrip_summary = validate_payload(out["exported"], require_complete=False)
        self.assertEqual(roundtrip_summary["human_completed_images"], 1)
        self.assertEqual(roundtrip_summary["ai_suggestions"], 1)
        _, upgraded_summary = validate_payload(out["upgraded"], require_complete=False)
        self.assertEqual(upgraded_summary["human_completed_images"], 1)


if __name__ == "__main__":
    unittest.main()
