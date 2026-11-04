#!/usr/bin/env python3
"""Fetch and verify the pinned PP-OCRv5 OCR models for a build.

This is a build/CI preparation tool only; the application itself never
downloads anything (ADR-005). Every artifact is pinned by repository revision,
byte size and SHA-256, and the bytes are hashed again after the download, so an
upstream change cannot silently alter what ships.

Artifacts (both Apache-2.0, exported by PaddlePaddle):

    PaddlePaddle/PP-OCRv5_mobile_det_onnx        inference.onnx
    PaddlePaddle/arabic_PP-OCRv5_mobile_rec_onnx inference.onnx

Usage:
    python tool/fetch_ocr_models.py            # fetch what is missing
    python tool/fetch_ocr_models.py --verify   # verify only, never download
"""

from __future__ import annotations

import hashlib
import sys
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Verification only: the character dictionary is committed because it is small,
# reviewable text that the unit tests read directly.
DICTIONARY = ROOT / "assets/ocr/ppocrv5_arabic_dict.txt"
DICTIONARY_SHA256 = "7f92f7dbb9b75a4787a83bfb4f6d14a8ab515525130c9d40a9036f61cf6999e9"
DICTIONARY_CHARACTERS = 747


@dataclass(frozen=True)
class Artifact:
    repository: str
    revision: str
    filename: str
    destination: Path
    size: int
    sha256: str

    @property
    def url(self) -> str:
        return (
            f"https://huggingface.co/{self.repository}/resolve/"
            f"{self.revision}/{self.filename}"
        )


ARTIFACTS = (
    Artifact(
        repository="PaddlePaddle/PP-OCRv5_mobile_det_onnx",
        revision="e6f4fa85f00e168c862bc462aebca69eef9b3d3d",
        filename="inference.onnx",
        destination=ROOT / "assets/models/ppocrv5_mobile_det.onnx",
        size=4_826_518,
        sha256="a431985659dc921974177a95adcfbb90fd9e51989a5e04d70d0b75f597b6e61d",
    ),
    Artifact(
        repository="PaddlePaddle/arabic_PP-OCRv5_mobile_rec_onnx",
        revision="14aaedcd75825982689ecf5cd64ab33ee083215a",
        filename="inference.onnx",
        destination=ROOT / "assets/models/ppocrv5_arabic_mobile_rec.onnx",
        size=7_998_947,
        sha256="799113ebf267fbe742deb99eb36e8d42c9ddc5291ceacf92add41b4d52a59110",
    ),
)


def digest(path: Path) -> tuple[int, str]:
    sha = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            size += len(block)
            sha.update(block)
    return size, sha.hexdigest()


def verify_dictionary() -> None:
    if not DICTIONARY.is_file():
        raise RuntimeError(f"missing committed OCR dictionary {DICTIONARY}")
    size, sha = digest(DICTIONARY)
    if sha != DICTIONARY_SHA256:
        raise RuntimeError(
            f"OCR dictionary digest changed: {sha} (expected {DICTIONARY_SHA256})"
        )
    characters = DICTIONARY.read_text(encoding="utf-8").splitlines()
    if len(characters) != DICTIONARY_CHARACTERS:
        raise RuntimeError(
            f"OCR dictionary has {len(characters)} characters, "
            f"expected {DICTIONARY_CHARACTERS}"
        )
    print(
        f"Verified OCR dictionary: bytes={size} sha256={sha} "
        f"characters={len(characters)}"
    )


def verify(artifact: Artifact) -> bool:
    if not artifact.destination.is_file():
        return False
    size, sha = digest(artifact.destination)
    if size != artifact.size or sha != artifact.sha256:
        raise RuntimeError(
            f"refusing to use unverified model {artifact.destination} "
            f"(size={size}, sha256={sha}); delete it and fetch again"
        )
    print(
        f"Verified {artifact.destination.name}: bytes={size} sha256={sha} "
        f"source={artifact.repository}@{artifact.revision}"
    )
    return True


def fetch(artifact: Artifact) -> None:
    artifact.destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        artifact.url,
        headers={
            "User-Agent": "Scan-id-pinned-model-fetch/1.0",
            "Accept": "application/octet-stream",
        },
    )
    print(f"Fetching {artifact.url}")
    with urllib.request.urlopen(request, timeout=300) as response:
        with tempfile.NamedTemporaryFile(
            dir=artifact.destination.parent,
            prefix=artifact.destination.name,
            suffix=".part",
            delete=False,
        ) as temporary:
            written = 0
            for block in iter(lambda: response.read(1024 * 1024), b""):
                temporary.write(block)
                written += len(block)
            temporary.flush()
            temporary_path = Path(temporary.name)
    try:
        size, sha = digest(temporary_path)
        if size != artifact.size or sha != artifact.sha256:
            raise RuntimeError(
                f"downloaded bytes do not match the pin for "
                f"{artifact.destination.name}: size={size} sha256={sha}"
            )
        # Rename only after the bytes are proven: a partial or substituted file
        # must never appear at the path the build reads.
        temporary_path.replace(artifact.destination)
    finally:
        temporary_path.unlink(missing_ok=True)
    print(
        f"Stored {artifact.destination} bytes={written} sha256={artifact.sha256}"
    )


def main(argv: list[str]) -> int:
    verify_only = "--verify" in argv
    verify_dictionary()
    for artifact in ARTIFACTS:
        if verify(artifact):
            continue
        if verify_only:
            raise RuntimeError(
                f"missing pinned OCR model {artifact.destination}; "
                "run without --verify to fetch it"
            )
        fetch(artifact)
        if not verify(artifact):
            raise RuntimeError(f"model {artifact.destination} is still missing")
    return 0


if __name__ == "__main__":
    if "--verify" not in sys.argv[1:] and len(sys.argv) > 1:
        print(f"unknown arguments: {sys.argv[1:]}", file=sys.stderr)
        raise SystemExit(2)
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as error:  # noqa: BLE001 - surfaced as a CI failure message
        print(f"::error title=ocr-models::{error}", file=sys.stderr)
        raise SystemExit(1)
