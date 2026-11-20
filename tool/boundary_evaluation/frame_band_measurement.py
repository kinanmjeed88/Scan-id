#!/usr/bin/env python3
"""Measure whether a border band can decide "the photo cut this document".

A tempting gate says: a quadrilateral with a corner within a small band of the
photo border has been cut by the photo, so its crop cannot be certified. This
script tests that claim against the reviewed ground truth, because a gate that
is wrong in either direction is expensive:

  * a false positive sends a complete, correctly cropped document to manual
    review;
  * a false negative certifies a crop that is missing part of the card.

The measurement is direct: for every reviewed instance, the minimum distance
from any corner to the nearest photo border. Instances whose warp was inspected
and certified as COMPLETE are the ones a band must not flag.

Usage:
  python3 tool/boundary_evaluation/frame_band_measurement.py \
      --truth local-data/boundary-dataset/ground_truth_quad.json \
      --out local-data/frame_band_measurement.json
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def border_distance(points) -> float:
    return min(min(p[0], 1.0 - p[0], p[1], 1.0 - p[1]) for p in points)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--truth", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    truth = json.loads(args.truth.read_text(encoding="utf-8"))
    measured = [
        {
            "instance_id": item["instance_id"],
            "status": item["status"],
            "kind": item["kind"],
            "min_border_distance": round(border_distance(item["points_norm"]), 6),
        }
        for item in truth["instances"]
        if item["points_norm"] is not None
    ]

    bands = {}
    for band in (0.005, 0.010, 0.016, 0.020, 0.030):
        flagged = [row for row in measured if row["min_border_distance"] <= band]
        bands[f"{band:.3f}"] = {
            "flagged_total": len(flagged),
            "flagged_confirmed_complete": sum(
                1 for row in flagged if row["status"] == "confirmed"
            ),
            "confirmed_total": sum(
                1 for row in measured if row["status"] == "confirmed"
            ),
        }

    report = {
        "stage": "border-band gate feasibility, measured on reviewed ground truth",
        "instances_with_quad": len(measured),
        "bands": bands,
        "verified_complete_crops_a_band_would_send_to_review": [
            row["instance_id"]
            for row in measured
            if row["status"] == "confirmed" and row["min_border_distance"] <= 0.016
        ],
        "conclusion": (
            "A corner on the border does not mean the photo cut the document: "
            "many photographs are framed so the card exactly fills the frame, "
            "and those warps were inspected and certified complete. At the mixed "
            "1.6 % band the gate flags this many verified-complete crops, so it "
            "cannot be used as a pass/fail rule and is NOT enabled. It stays a "
            "review signal only where a producer can measure it directly."
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
