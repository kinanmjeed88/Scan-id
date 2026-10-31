#!/usr/bin/env python3
"""Guard the manual-only intake state after retirement of the old detector."""

from __future__ import annotations

import hashlib
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

    allowed_docaligner = ROOT / "assets/models/docaligner_fastvit_sa24_7f9f5a89.onnx"
    for path in (ROOT / "assets").rglob("*.onnx"):
        if path != allowed_docaligner:
            errors.append(f"unreviewed ONNX model remains packaged under assets: {path.relative_to(ROOT)}")
    if allowed_docaligner.exists():
        docaligner_sha = "7f9f5a8935b2eb22b3ee0245d34996063f54562df390d34714af2d76928695bc"
        if allowed_docaligner.stat().st_size != 83_084_930:
            errors.append("DocAligner ONNX asset has an unexpected byte length")
        elif hashlib.sha256(allowed_docaligner.read_bytes()).hexdigest() != docaligner_sha:
            errors.append("DocAligner ONNX asset SHA-256 does not match the pinned upstream digest")

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
    if re.search(r"(?m)^\s*-\s*assets/models(?:/\*\*?|/\s*$|\s|$)", pubspec):
        errors.append("retired model directory or wildcard is still bundled as an asset")

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
    for token in (
        "implements ImageEditor, CropBytesImageEditor, BoundaryProposalImageEditor",
        "detectDocumentCornersScored(decoded)",
        "producer: BoundaryProducer.detector",
        "runCancellableIsolate(",
    ):
        if token not in editor:
            errors.append(f"local classical proposal path is missing required contract: {token}")
    model_path = ROOT / "assets/models/docquadnet256_trained_opset17.ort"
    expected_model_sha256 = "f0f2f52d7d79ff02d346c8f9d0c9e903407366aeea1747cdcff160c401e3e72a"
    if not model_path.is_file():
        errors.append("verified DocQuadNet-256 ORT asset is missing")
    elif hashlib.sha256(model_path.read_bytes()).hexdigest() != expected_model_sha256:
        errors.append("DocQuadNet-256 ORT asset SHA-256 does not match the reviewed weight")

    model_source_path = ROOT / "lib/imaging/docquad_model.dart"
    if not model_source_path.is_file():
        errors.append("DocQuadNet-256 ONNX Runtime adapter is missing")
    else:
        model_source = model_source_path.read_text(encoding="utf-8")
        for token in (
            "createSessionFromAsset(",
            "corner_heatmaps",
            "mask_logits",
            "BoundaryProducer.learnedModel",
            "minAutoAcceptConfidence: 1.01",
            "verifyBoundary(",
            "_minimumReviewEvidence",
        ):
            if token not in model_source:
                errors.append(f"DocQuadNet runtime contract is missing: {token}")
        if "download" in model_source.lower() or "http://" in model_source or "https://" in model_source:
            errors.append("model inference must not download weights or call a remote service")

    docaligner_source_path = ROOT / "lib/imaging/docaligner_model.dart"
    if not docaligner_source_path.is_file():
        errors.append("DocAligner 1.1.1 ONNX Runtime adapter is missing")
    else:
        docaligner_source = docaligner_source_path.read_text(encoding="utf-8")
        for token in (
            "createSessionFromAsset(",
            "session.inputNames.single",
            "session.outputNames.single",
            "session.run(",
            "_heatmapThreshold = 0.3",
            "BoundaryProducer.learnedModel",
            "minAutoAcceptConfidence: 1.01",
            "verifyBoundary(",
        ):
            if token not in docaligner_source:
                errors.append(f"DocAligner runtime contract is missing: {token}")
        if "download" in docaligner_source.lower() or "http://" in docaligner_source or "https://" in docaligner_source:
            errors.append("DocAligner inference must not download weights or call a remote service")

    cascade_path = ROOT / "lib/imaging/boundary_proposal_cascade.dart"
    if not cascade_path.is_file():
        errors.append("two-model boundary proposal cascade is missing")
    else:
        cascade_source = cascade_path.read_text(encoding="utf-8")
        for token in ("required this.primary", "required this.secondary", "_materiallyDisagrees(", "modelDisagreement"):
            if token not in cascade_source:
                errors.append(f"two-model cascade contract is missing: {token}")

    fetcher = ROOT / "tool/fetch_docaligner_model.py"
    if not fetcher.is_file():
        errors.append("verified DocAligner build-time fetch tool is missing")
    else:
        fetcher_source = fetcher.read_text(encoding="utf-8")
        for token in (
            "626727748",
            "83_084_930",
            "7f9f5a8935b2eb22b3ee0245d34996063f54562df390d34714af2d76928695bc",
            "browser_download_url",
            "os.replace",
        ):
            if token not in fetcher_source:
                errors.append(f"DocAligner source/weight verification is missing: {token}")

    integration_test = ROOT / "integration_test/docquad_inference_test.dart"
    if not integration_test.is_file():
        errors.append("real-model Android/Windows integration test is missing")
    else:
        integration_source = integration_test.read_text(encoding="utf-8")
        for token in ("docAlignerExpectedBytes", "docAlignerExpectedSha256", "inferenceRuns", "lastOutputShape"):
            if token not in integration_source:
                errors.append(f"real DocAligner inference evidence is missing: {token}")

    pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    for token in (
        "flutter_onnxruntime:",
        "assets/models/docquadnet256_trained_opset17.ort",
        "assets/models/docaligner_fastvit_sa24_7f9f5a89.onnx",
        "assets/legal/docquadnet-apache-2.0-LICENSE.txt",
        "assets/legal/flutter-onnxruntime-MIT-LICENSE.txt",
        "assets/legal/onnxruntime-LICENSE.txt",
    ):
        if token not in pubspec:
            errors.append(f"AI asset/dependency declaration is missing: {token}")

    decision = (ROOT / "lib/domain/boundary_decision.dart").read_text(
        encoding="utf-8"
    )
    if "BoundaryReviewReason.uncalibratedClassicalScore" not in decision:
        errors.append("classical score must be routed to manual review, not auto-accepted")

    return errors


def main() -> int:
    errors = verify()
    if errors:
        print("FAIL: detector retirement guard found violations:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print(
        "PASS: retired models remain absent; the pinned DocQuadNet and DocAligner "
        "offline ONNX Runtime adapters, model verification and CI inference paths "
        "are present; failed AI results fall back to the classical review-only proposer; schema "
        "v5 and annotation v2 remain."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
