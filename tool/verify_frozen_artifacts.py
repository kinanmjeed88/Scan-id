#!/usr/bin/env python3
"""Automated SHA-256 and frozen-threshold guard for Scan-id.

Verifies before and after every stage/evaluation that:
1. All frozen model weights, golden test fixtures, benchmark reports,
   evaluation definitions, and automatic boundary gate files match their
   pinned byte lengths and SHA-256 digests.
2. MODEL_MANIFEST.json neural frozen_thresholds and ONNX SHA-256 digests
   match the pinned values and actual ONNX files on disk.
3. Pinned regression case names (`wild_pos_jscanify_test3`,
   `jscanify_test7_truncated`) and `thresholds_modified_on_test == false`
   remain intact in `docs/reports/ai_boundary_benchmark_2026-10-22.json`.
4. Frozen routing thresholds in `lib/domain/recognition_routing.dart`
   remain unaltered (`autoAccept = .9`, `review = .7`, `componentFloor = .5`,
   `minClassification = .6`, `conflictGap = .15`).
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "tool" / "frozen_artifacts_manifest.json"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify() -> list[str]:
    errors: list[str] = []
    if not MANIFEST_PATH.is_file():
        return [f"Missing frozen manifest: {MANIFEST_PATH}"]

    spec = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    frozen_files: dict[str, dict[str, object]] = spec["frozen_files"]

    for rel, expected in sorted(frozen_files.items()):
        target = ROOT / rel
        if not target.is_file():
            errors.append(f"MISSING frozen file: {rel}")
            continue
        actual_size = target.stat().st_size
        actual_sha = _sha256(target)
        if actual_size != expected["size_bytes"]:
            errors.append(
                f"SIZE MISMATCH for {rel}: expected {expected['size_bytes']}, got {actual_size}"
            )
        if actual_sha != expected["sha256"]:
            errors.append(
                f"SHA-256 MISMATCH for {rel}: expected {expected['sha256']}, got {actual_sha}"
            )

    model_manifest_path = ROOT / "assets" / "models" / "MODEL_MANIFEST.json"
    if model_manifest_path.is_file():
        mm = json.loads(model_manifest_path.read_text(encoding="utf-8"))
        if mm.get("frozen_thresholds") != spec["frozen_neural_thresholds"]:
            errors.append("MODEL_MANIFEST.json frozen_thresholds diverged from pinned spec")
        for key in ("stage1_detector", "stage2_corner_refiner"):
            m_entry = mm.get("models", {}).get(key, {})
            rel_onnx = m_entry.get("file", "")
            onnx_path = ROOT / rel_onnx
            if not onnx_path.is_file():
                errors.append(f"Missing ONNX referenced by MODEL_MANIFEST: {rel_onnx}")
            else:
                if _sha256(onnx_path) != m_entry.get("sha256"):
                    errors.append(f"MODEL_MANIFEST internal sha256 mismatch for {key}")
                if onnx_path.stat().st_size != m_entry.get("size_bytes"):
                    errors.append(f"MODEL_MANIFEST internal size_bytes mismatch for {key}")

    bench_path = ROOT / "docs" / "reports" / "ai_boundary_benchmark_2026-10-22.json"
    if bench_path.is_file():
        bench = json.loads(bench_path.read_text(encoding="utf-8"))
        if bench.get("thresholds_modified_on_test") is not False:
            errors.append("Benchmark JSON thresholds_modified_on_test is not False")
        if bench.get("frozen_thresholds_used") != spec["frozen_neural_thresholds"]:
            errors.append("Benchmark JSON frozen_thresholds_used diverged from pinned spec")
        ledger = bench.get("track_a_wild_camera", {}).get("scene_ledger", [])
        scene_names = {entry.get("scene_id") for entry in ledger}
        for pinned_name in spec["pinned_regression_cases"]:
            if pinned_name not in scene_names:
                errors.append(f"Pinned regression case missing from Track A ledger: {pinned_name}")

    routing_path = ROOT / "lib" / "domain" / "recognition_routing.dart"
    if not routing_path.is_file():
        errors.append("Missing lib/domain/recognition_routing.dart")
    else:
        routing_src = routing_path.read_text(encoding="utf-8")
        expected_routing = {
            "autoAccept": 0.9,
            "review": 0.7,
            "componentFloor": 0.5,
            "minClassification": 0.6,
            "conflictGap": 0.15,
        }
        for field, exp_val in expected_routing.items():
            match = re.search(rf"this\.{field}\s*=\s*([0-9]*\.?[0-9]+)", routing_src)
            if not match:
                errors.append(f"Missing RoutingThresholds.{field} default in recognition_routing.dart")
            elif abs(float(match.group(1)) - exp_val) > 1e-12:
                errors.append(
                    f"RoutingThresholds.{field} modified: expected {exp_val}, got {match.group(1)}"
                )

    return errors


def main() -> int:
    errors = verify()
    if errors:
        print("FAIL: Frozen artifact guard detected violations:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1
    spec = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    print(
        f"PASS: Frozen artifact SHA-256 guard verified {len(spec['frozen_files'])} files, "
        f"14 neural thresholds, 5 routing thresholds, and "
        f"{len(spec['pinned_regression_cases'])} pinned regression cases."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
