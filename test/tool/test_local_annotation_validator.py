from __future__ import annotations

import copy
import hashlib
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

from tool.create_local_evaluation_splits import SPLITS, create_splits
from tool.validate_local_annotations import (
    ValidationError,
    compare,
    load_and_validate,
    main,
    polygon_iou,
)


FULL_QUAD = [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9], [0.1, 0.9]]


def annotation(reviewer: str = "R1") -> dict:
    return {
        "schema": "scan-id-local-annotations-v1",
        "reviewer_id": reviewer,
        "created_at": "2026-10-26T12:00:00Z",
        "coordinate_system": "normalized_xy_after_exif_orientation_clockwise_from_display_top_left",
        "reference_text_policy": "full text allowed only after manual visual review; local private JSON only",
        "samples": [
            {
                "sample_id": hashlib.sha256(b"private-local-fixture").hexdigest(),
                "width_px": 1000,
                "height_px": 800,
                "decode_status": "ok",
                "capture_group_id": "session-01",
                "review_status": "reviewed",
                "adjudication_status": "adjudicated",
                "no_document": False,
                "document_count": 1,
                "documents": [
                    {
                        "document_kind": "unifiedNationalId",
                        "visibility": "fully_visible",
                        "crop_quality": "acceptable",
                        "quality_flags": [],
                        "visible_polygon": copy.deepcopy(FULL_QUAD),
                        "quadrilateral": copy.deepcopy(FULL_QUAD),
                        "ocr_reference_text": "البطاقه الوطنيه",
                        "ocr_reference_verified": True,
                    }
                ],
            }
        ],
    }


class LocalAnnotationValidatorTest(unittest.TestCase):
    def load_payload(self, payload: dict, *, complete: bool = True):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "annotations.json"
            path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            return load_and_validate(path, require_complete=complete)

    def test_valid_adjudicated_sample_has_aggregate_summary_only(self):
        data, summary = self.load_payload(annotation())
        self.assertEqual(data["reviewer_id"], "R1")
        self.assertEqual(summary["samples"], 1)
        self.assertEqual(summary["documents"], 1)
        self.assertEqual(summary["kind_counts"]["unifiedNationalId"], 1)
        self.assertEqual(summary["groups"], 1)

    def test_cli_redacts_reviewer_codes_sample_ids_and_ocr_text(self):
        payload = annotation("reviewer-secret")
        sample_id = payload["samples"][0]["sample_id"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private-annotations.json"
            path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            output = StringIO()
            with patch("sys.argv", ["validate_local_annotations", str(path)]), redirect_stdout(output):
                self.assertEqual(main(), 0)
        text = output.getvalue()
        self.assertIn("reviewer code accepted (redacted)", text)
        self.assertNotIn("reviewer-secret", text)
        self.assertNotIn(sample_id, text)
        self.assertNotIn("البطاقه الوطنيه", text)

    def test_rejects_source_path_fields(self):
        payload = annotation()
        payload["samples"][0]["filename"] = "private.jpg"
        with self.assertRaisesRegex(ValidationError, "forbidden source-path/name"):
            self.load_payload(payload)

    def test_rejects_unverified_ocr_reference_without_echoing_text(self):
        payload = annotation()
        document = payload["samples"][0]["documents"][0]
        document["ocr_reference_text"] = "synthetic ID 12345678"
        document["ocr_reference_verified"] = False
        with self.assertRaisesRegex(ValidationError, "manually checked") as caught:
            self.load_payload(payload)
        self.assertNotIn("12345678", str(caught.exception))

    def test_verified_local_ocr_reference_accepts_digits_and_reports_count_only(self):
        payload = annotation()
        document = payload["samples"][0]["documents"][0]
        document["ocr_reference_text"] = "synthetic ID 12345678"
        document["ocr_reference_verified"] = True
        _, summary = self.load_payload(payload)
        self.assertEqual(summary["ocr_reference_documents"], 1)

    def test_ocr_reference_disagreement_is_aggregate_only(self):
        first, _ = self.load_payload(annotation("R1"))
        second_payload = annotation("R2")
        second_payload["samples"][0]["documents"][0]["ocr_reference_text"] = "different synthetic text"
        second, _ = self.load_payload(second_payload)
        result = compare(first, second, 1.0)
        self.assertEqual(result["ocr_reference_text_disagreements"], 1)
        self.assertNotIn("different synthetic text", json.dumps(result))

    def test_rejects_counter_clockwise_or_crossed_quadrilateral(self):
        payload = annotation()
        quad = [[0.1, 0.1], [0.1, 0.9], [0.9, 0.9], [0.9, 0.1]]
        payload["samples"][0]["documents"][0]["visible_polygon"] = quad
        payload["samples"][0]["documents"][0]["quadrilateral"] = quad
        with self.assertRaisesRegex(ValidationError, "clockwise"):
            self.load_payload(payload)

        payload = annotation()
        quad = [[0.1, 0.1], [0.9, 0.9], [0.9, 0.1], [0.1, 0.9]]
        payload["samples"][0]["documents"][0]["visible_polygon"] = quad
        payload["samples"][0]["documents"][0]["quadrilateral"] = quad
        with self.assertRaises(ValidationError):
            self.load_payload(payload)

    def test_polygon_iou_is_one_for_same_quadrilateral(self):
        points = [(x, y) for x, y in FULL_QUAD]
        self.assertAlmostEqual(polygon_iou(points, points), 1.0, places=9)

    def test_polygon_iou_handles_concave_visible_outline(self):
        outline = [(0.1, 0.1), (0.9, 0.1), (0.9, 0.4), (0.4, 0.4), (0.4, 0.9), (0.1, 0.9)]
        self.assertAlmostEqual(polygon_iou(outline, outline), 1.0, places=9)

    def test_independent_review_comparison_uses_aggregate_counts(self):
        first, _ = self.load_payload(annotation("R1"))
        second, _ = self.load_payload(annotation("R2"))
        result = compare(first, second, 1.0)
        self.assertEqual(result["common_samples"], 1)
        self.assertEqual(result["document_count_disagreements"], 0)
        self.assertEqual(result["kind_disagreements"], 0)
        self.assertEqual(result["mean_polygon_iou"], 1.0)
        self.assertEqual(result["polygon_iou_below_threshold"], 0)
        self.assertNotIn("sample_ids", result)

    def test_comparison_covers_status_quality_and_unmatched_outlines(self):
        first_payload = annotation("R1")
        second_payload = annotation("R2")
        sample = second_payload["samples"][0]
        sample["capture_group_id"] = "different-session"
        sample["review_status"] = "uncertain"
        sample["width_px"] = 999
        document = sample["documents"][0]
        document["document_kind"] = "passport"
        document["crop_quality"] = "unacceptable"
        document["quality_flags"] = ["blur"]
        document["ocr_reference_text"] = "different synthetic text"
        shifted = [[0.12, 0.1], [0.92, 0.1], [0.92, 0.9], [0.12, 0.9]]
        document["visible_polygon"] = shifted
        document["quadrilateral"] = shifted
        extra = copy.deepcopy(document)
        extra["visible_polygon"] = [[0.93, 0.93], [0.99, 0.93], [0.99, 0.99], [0.93, 0.99]]
        extra["quadrilateral"] = extra["visible_polygon"]
        sample["documents"].append(extra)
        sample["document_count"] = 2
        first, _ = self.load_payload(first_payload)
        second, _ = self.load_payload(second_payload, complete=False)

        result = compare(first, second, 1.0)
        self.assertEqual(result["capture_group_disagreements"], 1)
        self.assertEqual(result["review_status_disagreements"], 1)
        self.assertEqual(result["dimension_disagreements"], 1)
        self.assertEqual(result["document_count_disagreements"], 1)
        self.assertEqual(result["kind_disagreements"], 1)
        self.assertEqual(result["crop_quality_disagreements"], 1)
        self.assertEqual(result["quality_flag_disagreements"], 1)
        self.assertEqual(result["boundary_availability_disagreements"], 1)
        self.assertEqual(result["unmatched_outline_documents"], 1)
        self.assertEqual(result["ocr_reference_text_disagreements"], 1)
        self.assertEqual(result["polygon_iou_below_threshold"], 1)
        self.assertNotIn("different synthetic text", json.dumps(result))

    def test_polygon_disagreement_uses_only_an_explicit_threshold(self):
        first, _ = self.load_payload(annotation("R1"))
        second_payload = annotation("R2")
        shifted = [[0.12, 0.1], [0.92, 0.1], [0.92, 0.9], [0.12, 0.9]]
        second_payload["samples"][0]["documents"][0]["visible_polygon"] = shifted
        second_payload["samples"][0]["documents"][0]["quadrilateral"] = shifted
        second, _ = self.load_payload(second_payload)
        result = compare(first, second, 1.0)
        self.assertEqual(result["polygon_iou_below_threshold"], 1)
        self.assertLess(result["mean_polygon_iou"], 1.0)

    def test_require_complete_rejects_unadjudicated_sample(self):
        payload = annotation()
        payload["samples"][0]["adjudication_status"] = "not_adjudicated"
        with self.assertRaisesRegex(ValidationError, "not marked adjudicated"):
            self.load_payload(payload)

    def test_split_creation_requires_explicit_disjoint_complete_group_lists(self):
        payload = annotation()
        base = payload["samples"][0]
        payload["samples"] = []
        for index, group in enumerate(("train-01", "validation-01", "test-01")):
            sample = copy.deepcopy(base)
            sample["sample_id"] = hashlib.sha256(group.encode()).hexdigest()
            sample["capture_group_id"] = group
            payload["samples"].append(sample)
        assignments = {
            "train": {"train-01"},
            "validation": {"validation-01"},
            "test": {"test-01"},
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "adjudicated.json"
            path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            data, _ = load_and_validate(path, require_complete=True)
            splits, summary = create_splits(data, assignments, path)
        self.assertEqual(len(splits["assignments"]), 3)
        self.assertEqual(set(item["split"] for item in splits["assignments"]), set(SPLITS))
        self.assertEqual(summary["test"]["documents"], 1)

    def test_split_creation_rejects_leakage_and_missing_groups(self):
        payload = annotation()
        _, _ = self.load_payload(payload)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "adjudicated.json"
            path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            data, _ = load_and_validate(path, require_complete=True)
            with self.assertRaisesRegex(ValidationError, "more than one split"):
                create_splits(
                    data,
                    {"train": {"session-01"}, "validation": {"session-01"}, "test": {"other"}},
                    path,
                )
            with self.assertRaisesRegex(ValidationError, "cover every annotated"):
                create_splits(
                    data,
                    {"train": {"session-01"}, "validation": {"other"}, "test": {"test"}},
                    path,
                )


if __name__ == "__main__":
    unittest.main()
