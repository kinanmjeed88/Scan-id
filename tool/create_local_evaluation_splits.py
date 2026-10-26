#!/usr/bin/env python3
"""Create source/session-disjoint local splits from adjudicated annotations.

No split ratios or group assignments are guessed. The operator supplies three
explicit group lists after defining them without consulting held-out results.
The output contains IDs and group codes only; keep it in local-data/.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tool.validate_local_annotations import ValidationError, load_and_validate

SPLITS = ("train", "validation", "test")


def read_group_file(path: Path) -> set[str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ValidationError("a capture-group list could not be read.") from exc
    groups = {line.strip() for line in lines if line.strip() and not line.lstrip().startswith("#")}
    if not groups:
        raise ValidationError("each split requires at least one explicit capture group.")
    return groups


def create_splits(
    annotations: dict[str, Any],
    assignments: dict[str, set[str]],
    annotations_path: Path,
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    group_sets = [assignments[name] for name in SPLITS]
    if any(group_sets[i] & group_sets[j] for i in range(len(group_sets)) for j in range(i + 1, len(group_sets))):
        raise ValidationError("a capture group appears in more than one split.")
    sample_groups = {sample["capture_group_id"] for sample in annotations["samples"]}
    assigned_groups = set().union(*group_sets)
    if assigned_groups != sample_groups:
        raise ValidationError("explicit group lists must cover every annotated capture group exactly once.")

    by_group: dict[str, list[dict[str, Any]]] = {group: [] for group in sample_groups}
    for sample in annotations["samples"]:
        by_group[sample["capture_group_id"]].append(sample)

    entries = []
    summary: dict[str, dict[str, Any]] = {}
    for split in SPLITS:
        selected = [sample for group in sorted(assignments[split]) for sample in by_group[group]]
        classes: Counter[str] = Counter()
        unscorable = backgrounds = 0
        for sample in selected:
            if sample["review_status"] == "unscorable":
                unscorable += 1
            if sample["no_document"]:
                backgrounds += 1
            for document in sample["documents"]:
                classes[document["document_kind"]] += 1
            entries.append({"sample_id": sample["sample_id"], "capture_group_id": sample["capture_group_id"], "split": split})
        summary[split] = {
            "capture_groups": len(assignments[split]),
            "images": len(selected),
            "documents": sum(classes.values()),
            "background_images": backgrounds,
            "unscorable_images": unscorable,
            "document_kind_counts": dict(sorted(classes.items())),
        }
    output = {
        "schema": "scan-id-local-splits-v1",
        "source_annotations_sha256": hashlib.sha256(annotations_path.read_bytes()).hexdigest(),
        "group_disjointness": "capture_group_id; image-level random split is forbidden",
        "assignments": entries,
    }
    return output, summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--annotations", required=True, type=Path, help="adjudicated local annotations JSON")
    parser.add_argument("--train-groups", required=True, type=Path, help="text file: one capture group code per line")
    parser.add_argument("--validation-groups", required=True, type=Path, help="text file: one capture group code per line")
    parser.add_argument("--test-groups", required=True, type=Path, help="text file: one capture group code per line")
    parser.add_argument("--output", required=True, type=Path, help="private output path; use ignored local-data/")
    args = parser.parse_args()
    try:
        annotations, annotation_summary = load_and_validate(args.annotations, require_complete=True)
        if not annotations["reviewer_id"].startswith("ADJ"):
            raise ValidationError("the split source must be a separately marked adjudicator export (reviewer_id starts with ADJ).")
        assignments = {
            "train": read_group_file(args.train_groups),
            "validation": read_group_file(args.validation_groups),
            "test": read_group_file(args.test_groups),
        }
        output, summary = create_splits(annotations, assignments, args.annotations)
        output_path = args.output.resolve()
        local_data_root = (ROOT / "local-data").resolve()
        try:
            output_path.relative_to(ROOT.resolve())
            output_is_in_repo = True
        except ValueError:
            output_is_in_repo = False
        if output_is_in_repo and not output_path.is_relative_to(local_data_root):
            raise ValidationError("private split manifests inside the repository must stay under ignored local-data/.")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    except (ValidationError, OSError) as exc:
        print(f"FAIL: local split creation: {exc}", file=sys.stderr)
        return 1
    print("PASS: explicit session/source-disjoint splits created; no sample is assigned by filename.")
    print(f"Adjudicated annotation summary: samples={annotation_summary['samples']}, groups={annotation_summary['groups']}, documents={annotation_summary['documents']}.")
    for split in SPLITS:
        print(f"{split}: {json.dumps(summary[split], sort_keys=True)}")
    print("The test split must remain untouched during threshold/model tuning. Keep all output local and private.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
