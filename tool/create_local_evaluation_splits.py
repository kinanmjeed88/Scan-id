#!/usr/bin/env python3
"""Create source/session-disjoint local splits from adjudicated v2 annotations.

Enforces:
1. Explicit capture-group assignments (never image-level random or forced-ratio splits).
2. Complete human review + second-review adjudication before split creation.
3. Zero capture-group overlap across train / validation / test.
4. Zero near-duplicate cluster overlap and zero perceptual dHash64 leakage across splits.
5. Minimum statistical validity floor on the locked test split (refuses trivial splits).
6. Locally pinned test-set image IDs and fingerprints under ignored local-data/.
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

from tool.validate_local_annotations import (  # noqa: E402
     ValidationError,
    dhash64_hamming,
    load_and_validate,
)

SPLITS = ("train", "validation", "test")
FORBIDDEN_PLACEHOLDER_GROUPS = {"", "unknown", "unassigned", "none", "tbd", "na", "n/a"}
DEFAULT_NEAR_DUP_MAX_HAMMING = 10
DEFAULT_MIN_TEST_GROUPS = 3
DEFAULT_MIN_TEST_SCORABLE_DOCS = 10


def read_group_file(path: Path) -> set[str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ValidationError("a capture-group list file could not be read.") from exc
    groups = {
        line.strip()
        for line in lines
        if line.strip() and not line.lstrip().startswith("#")
    }
    if not groups:
        raise ValidationError("each split requires at least one explicit capture group.")
    if any(g.lower() in FORBIDDEN_PLACEHOLDER_GROUPS for g in groups):
        raise ValidationError("placeholder/unknown capture group codes cannot be used to create splits.")
    return groups


def create_splits(
    annotations: dict[str, Any],
    assignments: dict[str, set[str]],
    annotations_path: Path,
    *,
    near_duplicate_max_hamming: int = DEFAULT_NEAR_DUP_MAX_HAMMING,
    min_test_groups: int = DEFAULT_MIN_TEST_GROUPS,
    min_test_scorable_docs: int = DEFAULT_MIN_TEST_SCORABLE_DOCS,
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    if near_duplicate_max_hamming < 0 or near_duplicate_max_hamming > 32:
        raise ValidationError("near_duplicate_max_hamming must be between 0 and 32.")

    group_sets = [assignments[name] for name in SPLITS]
    if any(not group_sets[i] for i in range(len(SPLITS))):
        raise ValidationError("each split requires at least one explicit capture group.")
    for split_name in SPLITS:
        if any(g.lower() in FORBIDDEN_PLACEHOLDER_GROUPS for g in assignments[split_name]):
            raise ValidationError(
                f"{split_name} contains an unknown/placeholder capture_group_id; "
                "refusing to fabricate an unverified split."
            )

    if any(
        group_sets[i] & group_sets[j]
        for i in range(len(group_sets))
        for j in range(i + 1, len(group_sets))
    ):
        raise ValidationError("a capture group appears in more than one split (session leakage).")

    active_samples = [
        sample
        for sample in annotations["samples"]
        if sample["annotation_status"] != "excluded"
    ]
    if not active_samples:
        raise ValidationError("dataset has zero non-excluded samples.")

    for idx, sample in enumerate(active_samples, start=1):
        if sample["annotation_status"] != "second_review":
            raise ValidationError(
                f"active sample {idx} has not completed second_review adjudication."
            )
        grp = sample.get("capture_group_id", "").strip()
        if grp.lower() in FORBIDDEN_PLACEHOLDER_GROUPS:
            raise ValidationError(
                f"active sample {idx} has an unknown or empty capture_group_id; "
                "independent splits cannot be created without verified source/session provenance."
            )
        if not sample.get("perceptual_dhash64"):
            raise ValidationError(
                f"active sample {idx} is missing perceptual_dhash64 required for cross-split duplicate verification."
            )

    sample_groups = {sample["capture_group_id"] for sample in active_samples}
    assigned_groups = set().union(*group_sets)
    if assigned_groups != sample_groups:
        raise ValidationError(
            "explicit group lists must cover every non-excluded capture_group_id exactly once."
        )

    by_group: dict[str, list[dict[str, Any]]] = {group: [] for group in sample_groups}
    for sample in active_samples:
        by_group[sample["capture_group_id"]].append(sample)

    sample_to_split: dict[str, str] = {}
    cluster_to_split: dict[str, str] = {}
    split_samples: dict[str, list[dict[str, Any]]] = {name: [] for name in SPLITS}

    for split in SPLITS:
        for group in sorted(assignments[split]):
            for sample in by_group[group]:
                img_id = sample["image_id"]
                if img_id in sample_to_split:
                    raise ValidationError("duplicate image_id assignment across splits.")
                sample_to_split[img_id] = split
                cluster = sample.get("near_duplicate_cluster_id", "")
                if cluster:
                    prev_split = cluster_to_split.get(cluster)
                    if prev_split is not None and prev_split != split:
                        raise ValidationError(
                            f"near_duplicate_cluster_id {cluster!r} spans {prev_split} and {split} (duplicate leakage)."
                        )
                    cluster_to_split[cluster] = split
                split_samples[split].append(sample)

    # Cross-split perceptual near-duplicate check
    for i, split_a in enumerate(SPLITS):
        for split_b in SPLITS[i + 1 :]:
            for sa in split_samples[split_a]:
                for sb in split_samples[split_b]:
                    ham = dhash64_hamming(sa["perceptual_dhash64"], sb["perceptual_dhash64"])
                    if ham <= near_duplicate_max_hamming:
                        raise ValidationError(
                            f"cross-split near-duplicate detected between {split_a} and {split_b} "
                            f"(dHash64 Hamming distance={ham} <= {near_duplicate_max_hamming})."
                        )

    entries: list[dict[str, Any]] = []
    summary: dict[str, dict[str, Any]] = {}
    for split in SPLITS:
        selected = split_samples[split]
        classes: Counter[str] = Counter()
        scorable_docs = 0
        backgrounds = 0
        for sample in selected:
            if sample["no_document"]:
                backgrounds += 1
            for doc in sample["documents"]:
                classes[doc["document_kind"]] += 1
                if doc["boundary_status"] != "undeterminable":
                    scorable_docs += 1
            entries.append(
                {
                    "image_id": sample["image_id"],
                    "internal_code": sample.get("internal_code", ""),
                    "capture_group_id": sample["capture_group_id"],
                    "perceptual_dhash64": sample["perceptual_dhash64"],
                    "split": split,
                }
            )
        summary[split] = {
            "capture_groups": len(assignments[split]),
            "images": len(selected),
            "documents": sum(classes.values()),
            "scorable_boundary_documents": scorable_docs,
            "background_images": backgrounds,
            "document_kind_counts": dict(sorted(classes.items())),
        }

    if summary["test"]["capture_groups"] < min_test_groups:
        raise ValidationError(
            f"test split has only {summary['test']['capture_groups']} independent capture group(s); "
            f"at least {min_test_groups} are required for a statistically meaningful evaluation."
        )
    if summary["test"]["scorable_boundary_documents"] < min_test_scorable_docs:
        raise ValidationError(
            f"test split has only {summary['test']['scorable_boundary_documents']} scorable boundary document(s); "
            f"at least {min_test_scorable_docs} are required."
        )

    locked_test = sorted(
        (
            {
                "image_id": item["image_id"],
                "internal_code": item["internal_code"],
                "capture_group_id": item["capture_group_id"],
                "perceptual_dhash64": item["perceptual_dhash64"],
            }
            for item in entries
            if item["split"] == "test"
        ),
        key=lambda r: r["image_id"],
    )
    locked_test_sha256 = hashlib.sha256(
        "\n".join(item["image_id"] for item in locked_test).encode("utf-8")
    ).hexdigest()

    excluded_entries = [
        {
            "image_id": s["image_id"],
            "internal_code": s.get("internal_code", ""),
            "exclusion_reason": s["exclusion_reason"],
        }
        for s in annotations["samples"]
        if s["annotation_status"] == "excluded"
    ]

    output: dict[str, Any] = {
        "schema": "scan-id-local-splits-v2",
        "schema_version": "2.0.0",
        "source_annotations_sha256": hashlib.sha256(annotations_path.read_bytes()).hexdigest(),
        "group_disjointness": "capture_group_id + near_duplicate_cluster_id + perceptual_dhash64",
        "near_duplicate_max_hamming_enforced": near_duplicate_max_hamming,
        "threshold_tuning_on_test_forbidden": True,
        "locked_test_set_sha256": locked_test_sha256,
        "locked_test_manifest": locked_test,
        "excluded_samples": excluded_entries,
        "assignments": entries,
    }
    return output, summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--annotations", required=True, type=Path, help="adjudicated local v2 annotations JSON")
    parser.add_argument("--images-dir", type=Path, help="optional local image directory to verify hashes and dHashes on disk")
    parser.add_argument("--train-groups", required=True, type=Path, help="text file: one capture group code per line")
    parser.add_argument("--validation-groups", required=True, type=Path, help="text file: one capture group code per line")
    parser.add_argument("--test-groups", required=True, type=Path, help="text file: one capture group code per line")
    parser.add_argument("--near-duplicate-hamming-threshold", type=int, default=DEFAULT_NEAR_DUP_MAX_HAMMING)
    parser.add_argument("--min-test-groups", type=int, default=DEFAULT_MIN_TEST_GROUPS)
    parser.add_argument("--min-test-scorable-docs", type=int, default=DEFAULT_MIN_TEST_SCORABLE_DOCS)
    parser.add_argument("--output", required=True, type=Path, help="private output path under ignored local-data/")
    args = parser.parse_args()

    try:
        annotations, annotation_summary = load_and_validate(
            args.annotations,
            require_complete=True,
            images_dir=args.images_dir,
        )
        if not annotations["annotator_id"].startswith("ADJ"):
            raise ValidationError(
                "the split source must be an adjudicated export whose annotator_id starts with 'ADJ'."
            )
        assignments = {
            "train": read_group_file(args.train_groups),
            "validation": read_group_file(args.validation_groups),
            "test": read_group_file(args.test_groups),
        }
        output, summary = create_splits(
            annotations,
            assignments,
            args.annotations,
            near_duplicate_max_hamming=args.near_duplicate_hamming_threshold,
            min_test_groups=args.min_test_groups,
            min_test_scorable_docs=args.min_test_scorable_docs,
        )
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

    print("PASS: explicit session/source-disjoint and duplicate-free splits created.")
    print(
        f"Adjudicated dataset: total_samples={annotation_summary['samples']}, "
        f"active_groups={annotation_summary['capture_groups']}, "
        f"locked_test_set_sha256={output['locked_test_set_sha256'][:16]}..."
    )
    for split in SPLITS:
        print(f"{split}: {json.dumps(summary[split], sort_keys=True)}")
    print("The locked test split must never be used for model or threshold tuning.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
