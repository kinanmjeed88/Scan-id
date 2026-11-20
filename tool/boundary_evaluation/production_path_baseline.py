#!/usr/bin/env python3
"""Measure what the SHIPPED intake path can achieve on the boundary dataset.

The shipped configuration is not "run the segmenter over every image". It is:

  * `multiDocumentSegmentationEnabled = false`, and `defaultSegment` returns an
    empty candidate list, so region segmentation does not run at all in
    production; one photo yields at most ONE document, from the whole-frame
    corner detector;
  * therefore at most one instance per image can ever be produced, whatever the
    number of documents in the picture.

This script measures the CEILING of that configuration against the reviewed
ground truth, without running any detector: it counts how many ground-truth
instances a one-document-per-photo architecture can possibly represent. That is
the number the multi-document goal has to beat, and it is a measurement, not an
estimate.

Usage:
  python3 tool/boundary_evaluation/production_path_baseline.py \
      --truth local-data/boundary-dataset/ground_truth_quad.json \
      --out local-data/baseline_production_path.json
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--truth", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    truth = json.loads(args.truth.read_text(encoding="utf-8"))
    instances = truth["instances"]

    by_image: dict[int, list[dict]] = {}
    for instance in instances:
        by_image.setdefault(instance["image_index"], []).append(instance)

    with_quad = [i for i in instances if i["points_norm"] is not None]
    # One document per photo can at best carry the FIRST instance of each image.
    representable = 0
    images_multi = 0
    for index, entries in sorted(by_image.items()):
        representable += 1
        if len(entries) > 1:
            images_multi += 1

    report = {
        "stage": "shipped production configuration ceiling (no detector run)",
        "configuration": {
            "multiDocumentSegmentationEnabled": False,
            "defaultSegment": "returns no candidates",
            "max_documents_per_photo": 1,
        },
        "images": len(by_image),
        "instances_reviewed": len(instances),
        "instances_with_quad": len(with_quad),
        "instances_confirmed": sum(
            1 for i in instances if i["status"] == "confirmed"
        ),
        "images_holding_several_documents": images_multi,
        "instances_a_one_document_path_can_represent": representable,
        "instance_recall_ceiling": round(representable / len(instances), 4),
        "unrepresentable_instances": len(instances) - representable,
        "reading": (
            "One document per photograph cannot express more than one instance "
            "per image, so recall is bounded by the number of images. Every "
            "second and later document in a multi-document photo is lost by the "
            "architecture before any detector quality is involved."
        ),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
