#!/usr/bin/env python3
"""Guard the manual-only intake state after retirement of the old detector."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_PATHS = (
    "assets/models/MODEL_MANIFEST.json",
    "assets/models/scanid_stage1_det_v1.onnx",
    "assets/models/scanid_stage2_corners_v1.onnx",
    "assets/legal/scanid-docnet-v1-LICENSE.txt",
    "lib/imaging/ai_document_detector.dart",
    "lib/imaging/onnx_lite_runtime.dart",
    "lib/imaging/hybrid_boundary_arbitrator.dart",
    "tool/ai",
)
FORBIDDEN_RUNTIME_TOKENS = (
    "scanid-docnet-v1",
    "scanid_stage1_det_v1.onnx",
    "scanid_stage2_corners_v1.onnx",
    "MODEL_MANIFEST.json",
    "AiDocumentDetector",
    "OnnxLiteRuntime",
    "HybridBoundaryArbitrator",
    "detectSceneWithAiBundle",
    "loadVerifiedAiBundle",
    "scanIdStage1AssetPath",
    "scanIdStage2AssetPath",
    "scanIdManifestAssetPath",
    "ai_document_detector.dart",
    "onnx_lite_runtime.dart",
    "hybrid_boundary_arbitrator.dart",
    "_dart_detector_mirror",
    "detect_full_pipeline",
    "use_learned_model",
    "include-ai-suggestions",
    "include_ai_suggestions",
    "_compute_ai_suggestions_for_image",
)
PRODUCTION_PATHS = (
    "lib",
    "android/app/src",
    "windows",
    "pubspec.yaml",
    "android/app/build.gradle.kts",
    # This local-only tool must remain a metadata/annotation inventory, not an
    # entry point that can revive the retired model or depend on removed code.
    "tool/inventory_local_mostmskat.py",
)


def production_files() -> list[Path]:
    files: list[Path] = []
    for rel in PRODUCTION_PATHS:
        path = ROOT / rel
        if path.is_file():
            files.append(path)
        elif path.is_dir():
            files.extend(child for child in path.rglob("*") if child.is_file())
    return files


def verify() -> list[str]:
    errors: list[str] = []
    for rel in FORBIDDEN_PATHS:
        if (ROOT / rel).exists():
            errors.append(f"retired model artifact or implementation still exists: {rel}")

    for path in (ROOT / "assets").rglob("*.onnx"):
        errors.append(f"ONNX model remains packaged under assets: {path.relative_to(ROOT)}")

    for path in production_files():
        try:
            source = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for token in FORBIDDEN_RUNTIME_TOKENS:
            if token in source:
                errors.append(
                    "retired model invocation, weight, or runtime path remains "
                    f"in production source {path.relative_to(ROOT)}: {token}"
                )

    pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    if re.search(r"(?m)^\s*-\s*assets/models(?:/|\s|$)", pubspec):
        errors.append("retired model directory is still bundled as an asset")

    flags = (ROOT / "lib/application/multi_document_segmentation_flag.dart").read_text(
        encoding="utf-8"
    )
    if not re.search(
        r"const\s+bool\s+multiDocumentSegmentationEnabled\s*=\s*false\s*;",
        flags,
    ):
        errors.append("automatic multi-document segmentation is not disabled by default")

    pipeline = (ROOT / "lib/application/recognition_pipeline.dart").read_text(
        encoding="utf-8"
    )
    default_start = pipeline.find("Future<SegmentationResult> defaultSegment(")
    default_end = pipeline.find(";", default_start) if default_start >= 0 else -1
    if default_start < 0 or default_end < 0:
        errors.append("safe defaultSegment implementation is missing")
    else:
        expression = pipeline[default_start:default_end]
        if "segmentDocumentBytes" in expression or "candidates: []" not in expression:
            errors.append("defaultSegment must return empty candidates, not run a detector")

    project = (ROOT / "lib/domain/project.dart").read_text(encoding="utf-8")
    if not re.search(r"static\s+const\s+schemaVersion\s*=\s*5\s*;", project):
        errors.append("Project.schemaVersion must remain 5")

    annotation_schema = ROOT / "tool/schemas/local_reference_dataset_v2.schema.json"
    if not annotation_schema.is_file() or '"scan-id-local-annotations-v2"' not in annotation_schema.read_text(
        encoding="utf-8"
    ):
        errors.append("scan-id-local-annotations-v2 schema must remain available")

    recognition = (ROOT / "lib/domain/recognition.dart").read_text(encoding="utf-8")
    if "final List<Point2>? polygon;" not in recognition:
        errors.append("human-approved polygon field must remain intact")
    if "final List<Point2>? suggestedPolygon;" not in recognition:
        errors.append("suggestedPolygon must remain separate from human polygon")

    editor = (ROOT / "lib/persistence/local_image_editor.dart").read_text(
        encoding="utf-8"
    )
    if not re.search(
        r"Future<List<Point2>\?>\s+suggest\(Uint8List\s+_\)\s+async\s*=>\s*null\s*;",
        editor,
    ):
        errors.append("production image editor must not return automatic corner proposals")

    return errors


def main() -> int:
    errors = verify()
    if errors:
        print("FAIL: detector retirement guard found violations:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print(
        "PASS: retired model artifacts, calls, and runtime paths are absent; "
        "production intake is manual-only; schema v5 and annotation v2 remain."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
