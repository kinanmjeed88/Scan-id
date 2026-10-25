#!/usr/bin/env python3
"""Run an aggregate-only, offline screen of the local Mostmskat JPEGs.

This is not a labelled accuracy benchmark: the local sample has no verified
per-document count, corner annotations, or OCR transcription. The command reads
still images from Mostmskat/ in memory, applies EXIF orientation and the Python
BOX preview-resize approximation (max edge 1200), then compares the checked-in
frozen ONNX hybrid pipeline with its classical-only path. It never reads the
video or SCANID backup, emits per-image records, saves pixels/text, or contacts
a service.

Run from the repository root after installing the local evaluation dependencies:
  python tool/evaluate_local_mostmskat.py

The aggregate JSON is written under ignored local-data/ by default.
"""

from __future__ import annotations

import hashlib
import json
import platform
import subprocess
import sys
import time
from collections import Counter
from datetime import date
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime
from PIL import Image, ImageOps, __version__ as pillow_version

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INPUT = ROOT / "Mostmskat"
DEFAULT_OUTPUT = ROOT / "local-data" / "mostmskat-local-evaluation-summary.json"
MODEL_DIR = ROOT / "assets" / "models"
PREVIEW_LONG_EDGE = 1200
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def preview_rgb(image: Image.Image) -> np.ndarray:
    """Mirror the app's EXIF normalization and 1200px preview boundary."""
    oriented = ImageOps.exif_transpose(image).convert("RGB")
    width, height = oriented.size
    longest = max(width, height)
    if longest > PREVIEW_LONG_EDGE:
        scale = PREVIEW_LONG_EDGE / float(longest)
        size = (
            max(1, int(round(width * scale))),
            max(1, int(round(height * scale))),
        )
        oriented = oriented.resize(size, Image.Resampling.BOX)
    return np.asarray(oriented, dtype=np.uint8)


def _new_aggregate() -> dict[str, Any]:
    return {
        "images_processed": 0,
        "inference_errors": 0,
        "candidate_decisions": 0,
        "images_with_multiple_regions": 0,
        "images_with_usable_geometry": 0,
        "images_with_automatic_acceptance": 0,
        "images_with_uncorroborated_multi_review": 0,
        "image_status": Counter(),
        "decision_outcomes": Counter(),
        "boundary_producers": Counter(),
        "review_reasons": Counter(),
        "latencies_ms": [],
    }


def _record_run(aggregate: dict[str, Any], decisions: list[Any]) -> None:
    aggregate["images_processed"] += 1
    aggregate["candidate_decisions"] += len(decisions)
    if len(decisions) > 1:
        aggregate["images_with_multiple_regions"] += 1

    kinds = {decision.kind for decision in decisions}
    if "accepted" in kinds:
        aggregate["image_status"]["has_accepted_candidate"] += 1
        aggregate["images_with_automatic_acceptance"] += 1
    elif "needsReview" in kinds:
        aggregate["image_status"]["review_only"] += 1
    else:
        aggregate["image_status"]["no_accepted_or_review_candidate"] += 1

    if any(decision.has_usable_geometry for decision in decisions):
        aggregate["images_with_usable_geometry"] += 1
    if any(
        "multiSceneNotCorroborated" in decision.reasons for decision in decisions
    ):
        aggregate["images_with_uncorroborated_multi_review"] += 1

    for decision in decisions:
        aggregate["decision_outcomes"][decision.kind] += 1
        aggregate["boundary_producers"][decision.proposal.producer] += 1
        aggregate["review_reasons"].update(decision.reasons)


def _finalize_aggregate(aggregate: dict[str, Any]) -> dict[str, Any]:
    latencies = aggregate.pop("latencies_ms")
    aggregate["latency_ms_per_image"] = {
        "p50": round(float(np.percentile(latencies, 50)), 3) if latencies else None,
        "p95": round(float(np.percentile(latencies, 95)), 3) if latencies else None,
        "max": round(max(latencies), 3) if latencies else None,
        "interpretation": (
            "local host only; inference excludes file decode/preview preparation "
            "and is not Android or Windows device performance"
        ),
    }
    for field in (
        "image_status",
        "decision_outcomes",
        "boundary_producers",
        "review_reasons",
    ):
        aggregate[field] = dict(sorted(aggregate[field].items()))
    return aggregate


def evaluate(input_dir: Path) -> dict[str, Any]:
    if not input_dir.is_dir():
        raise FileNotFoundError("local input directory is unavailable")
    if not (MODEL_DIR / "MODEL_MANIFEST.json").is_file():
        raise FileNotFoundError("checked-in model manifest is unavailable")

    # Import the repository's decision mirror and frozen-artifact verifier only
    # after setting the root explicitly; ONNX model files remain local and are
    # never fetched.
    sys.path.insert(0, str(ROOT))
    sys.path.insert(0, str(ROOT / "test" / "tool"))
    import _dart_detector_mirror as mirror  # noqa: E402

    from tool.verify_frozen_artifacts import verify as verify_frozen_artifacts  # noqa: E402

    frozen_errors = verify_frozen_artifacts()
    if frozen_errors:
        raise RuntimeError("frozen model/gate integrity verification failed")

    manifest_path = MODEL_DIR / "MODEL_MANIFEST.json"
    model_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    image_paths = sorted(
        path
        for path in input_dir.rglob("*")
        if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES
    )
    if not image_paths:
        raise RuntimeError("no local still images found")

    aggregates = {
        "frozen_ai_hybrid": _new_aggregate(),
        "classical_only": _new_aggregate(),
    }
    decode_errors = 0
    processed_any = 0

    for image_path in image_paths:
        # No basename, EXIF field, OCR string, region coordinates, or image bytes
        # are copied into the report or printed.
        try:
            with Image.open(image_path) as image:
                rgb = preview_rgb(image)
        except Exception:
            decode_errors += 1
            continue
        processed_any += 1

        for mode, use_learned_model in (
            ("frozen_ai_hybrid", True),
            ("classical_only", False),
        ):
            aggregate = aggregates[mode]
            start = time.perf_counter()
            try:
                decisions = mirror.detect_full_pipeline(
                    rgb,
                    use_learned_model=use_learned_model,
                    models_dir=MODEL_DIR,
                    filename="local-anonymous-image",
                )
            except Exception:
                aggregate["inference_errors"] += 1
                aggregate["latencies_ms"].append(
                    (time.perf_counter() - start) * 1000.0
                )
                continue
            aggregate["latencies_ms"].append(
                (time.perf_counter() - start) * 1000.0
            )
            _record_run(aggregate, decisions)

    if processed_any == 0 or not any(
        aggregate["images_processed"] for aggregate in aggregates.values()
    ):
        raise RuntimeError("no still images completed the local evaluation")

    model_entries = model_manifest.get("models", {})
    model_hashes = {
        str(entry.get("file", key)): str(entry.get("sha256", ""))
        for key, entry in sorted(model_entries.items())
    }
    thresholds = model_manifest.get("frozen_thresholds", {})
    try:
        commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        commit = "unavailable"

    summary: dict[str, Any] = {
        "evaluation_date_local": date.today().isoformat(),
        "purpose": "unlabelled local behavior screen; not an accuracy estimate",
        "privacy": {
            "input_scope": "local still images only",
            "input_count": len(image_paths),
            "per_image_output_saved": False,
            "image_or_video_bytes_saved": False,
            "ocr_text_read_or_saved": False,
            "network_or_external_service_used": False,
            "video_and_project_backup_read": False,
        },
        "preprocessing": {
            "exif_orientation": "Pillow ImageOps.exif_transpose",
            "preview_long_edge_px": PREVIEW_LONG_EDGE,
            "resize": "Pillow BOX approximation; Dart/package:image parity requires Flutter CI",
            "filename_evidence": "neutral placeholder; local filenames are not used",
        },
        "implementation": {
            "git_head": commit,
            "evaluation_script_sha256": sha256(Path(__file__).resolve()),
            "python_mirror_sha256": sha256(ROOT / "test" / "tool" / "_dart_detector_mirror.py"),
        },
        "model": {
            "manifest_sha256": sha256(manifest_path),
            "model_sha256": model_hashes,
            "frozen_thresholds": thresholds,
        },
        "runtime": {
            "python": platform.python_version(),
            "pillow": pillow_version,
            "numpy": np.__version__,
            "onnxruntime": onnxruntime.__version__,
            "host_platform": platform.system(),
        },
        "decode_errors": decode_errors,
        "runs": {
            mode: _finalize_aggregate(aggregate)
            for mode, aggregate in aggregates.items()
        },
        "limitations": [
            "No independent image-level document-count or corner ground truth was available.",
            "Counts describe mirror decisions only and do not estimate precision, recall, CER, or WER.",
            "The Python mirror is not a substitute for Dart/Flutter tests or device builds.",
            "No OCR engine is integrated; this run evaluates no recognized text.",
            "A 1200px Pillow BOX resize approximates package:image; cross-runtime parity remains unverified without Dart/Flutter.",
        ],
    }
    return summary


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    try:
        summary = evaluate(args.input_dir.resolve())
        output = args.output.resolve()
        # Keep generated aggregates in the ignored local-data directory so a
        # private local run cannot accidentally become a source/CI artifact.
        if ROOT / "local-data" not in output.parents:
            raise ValueError("output must remain under ignored local-data/")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(
            json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        print(
            "Aggregate summary saved under ignored local-data/: "
            f"{output.relative_to(ROOT)}"
        )
    except Exception as error:
        # Error type is useful for debugging; input names and exception messages
        # may contain private paths or metadata and are deliberately suppressed.
        print(
            f"Local evaluation failed ({type(error).__name__}); no input details emitted.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
