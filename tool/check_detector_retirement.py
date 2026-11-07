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

    # Every ONNX weight that may sit under assets/ is listed with its exact byte
    # length and SHA-256. A new model therefore cannot be dropped into the app
    # without being reviewed and pinned here, and a substituted or truncated file
    # is caught by digest rather than trusted because it happens to be present.
    allowed_onnx = {
        "assets/models/docaligner_fastvit_sa24_7f9f5a89.onnx": (
            83_084_930,
            "7f9f5a8935b2eb22b3ee0245d34996063f54562df390d34714af2d76928695bc",
        ),
        "assets/models/ppocrv5_mobile_det.onnx": (
            4_826_518,
            "a431985659dc921974177a95adcfbb90fd9e51989a5e04d70d0b75f597b6e61d",
        ),
        "assets/models/ppocrv5_arabic_mobile_rec.onnx": (
            7_998_947,
            "799113ebf267fbe742deb99eb36e8d42c9ddc5291ceacf92add41b4d52a59110",
        ),
    }
    for path in (ROOT / "assets").rglob("*.onnx"):
        relative = path.relative_to(ROOT).as_posix()
        pin = allowed_onnx.get(relative)
        if pin is None:
            errors.append(f"unreviewed ONNX model remains packaged under assets: {relative}")
            continue
        expected_size, expected_sha = pin
        if path.stat().st_size != expected_size:
            errors.append(f"{relative} has an unexpected byte length")
        elif hashlib.sha256(path.read_bytes()).hexdigest() != expected_sha:
            errors.append(f"{relative} SHA-256 does not match the pinned upstream digest")

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

    alphabet = ROOT / "assets/ocr/ppocrv5_arabic_dict.txt"
    if not alphabet.is_file():
        errors.append("committed OCR alphabet is missing")
    else:
        alphabet_sha = (
            "7f92f7dbb9b75a4787a83bfb4f6d14a8ab515525130c9d40a9036f61cf6999e9"
        )
        alphabet_bytes = alphabet.read_bytes().replace(b"\r\n", b"\n")
        if hashlib.sha256(alphabet_bytes).hexdigest() != alphabet_sha:
            errors.append("OCR alphabet SHA-256 does not match the pinned digest")
        if len(alphabet.read_text(encoding="utf-8").splitlines()) != 747:
            errors.append("OCR alphabet must keep all 747 characters")

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

    policy = (ROOT / "lib/domain/acceptance_policy.dart").read_text(encoding="utf-8")
    if not re.search(r"const\s+double\s+automaticAcceptanceThreshold\s*=\s*\.70\s*;", policy):
        errors.append("the shared automatic acceptance threshold must remain 70%")

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
            "minAutoAcceptConfidence: automaticAcceptanceThreshold",
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
            "minAutoAcceptConfidence: automaticAcceptanceThreshold",
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

    ocr_fetcher = ROOT / "tool/fetch_ocr_models.py"
    if not ocr_fetcher.is_file():
        errors.append("verified OCR model fetch tool is missing")
    else:
        ocr_fetcher_source = ocr_fetcher.read_text(encoding="utf-8")
        for token in (
            "4_826_518",
            "7_998_947",
            "a431985659dc921974177a95adcfbb90fd9e51989a5e04d70d0b75f597b6e61d",
            "799113ebf267fbe742deb99eb36e8d42c9ddc5291ceacf92add41b4d52a59110",
            "temporary_path.replace(",
        ):
            if token not in ocr_fetcher_source:
                errors.append(f"OCR source/weight verification is missing: {token}")

    for relative in ("lib/application/paddle_ocr_engine.dart", "lib/application/paddle_ocr_runtime.dart"):
        adapter = ROOT / relative
        if not adapter.is_file():
            errors.append(f"OCR runtime adapter is missing: {relative}")
            continue
        adapter_source = adapter.read_text(encoding="utf-8")
        if "http://" in adapter_source or "https://" in adapter_source:
            errors.append(f"OCR inference must not call a remote service: {relative}")
        if "download" in adapter_source.lower():
            errors.append(f"OCR inference must not download weights: {relative}")

    engine = ROOT / "lib/application/paddle_ocr_engine.dart"
    if engine.is_file():
        engine_source = engine.read_text(encoding="utf-8")
        for token in (
            "Isolate.run(",
            "decodeTextBoxes(",
            "decodeCtcLine(",
            "OperationCancelled",
            "OcrTextResult.unavailable(",
        ):
            if token not in engine_source:
                errors.append(f"OCR engine contract is missing: {token}")

    main_source = (ROOT / "lib/main.dart").read_text(encoding="utf-8")
    if "createPlatformOcrEngine()" not in main_source:
        errors.append("the production project service is not wired to the OCR engine")
    if "smartRecognitionEnabled: appSmartRecognitionEnabled" not in main_source:
        errors.append("the shipped app does not enable the recognition pipeline")

    windows_workflow = (ROOT / ".github/workflows/windows-release.yml").read_text(
        encoding="utf-8"
    )
    if "integration_test/ocr_inference_test.dart" not in windows_workflow:
        errors.append("real OCR inference is not executed in CI")

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
