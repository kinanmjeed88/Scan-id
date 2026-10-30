#!/usr/bin/env python3
"""Fetch and verify the pinned DocAligner 1.1.1 release asset for a build.

This is a build/CI preparation tool only; the application never downloads a
model. It uses the official GitHub release API and browser-download URL, checks
the published asset identity/size/digest, then independently hashes the bytes.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import urllib.request
from pathlib import Path

REPOSITORY = "DocsaidLab/DocAligner"
RELEASE_TAG = "1.1.1"
ASSET_ID = 626727748
ASSET_NAME = "fastvit_sa24_h_e_bifpn_256_fp32.onnx"
EXPECTED_BYTES = 83_084_930
EXPECTED_SHA256 = "7f9f5a8935b2eb22b3ee0245d34996063f54562df390d34714af2d76928695bc"
DESTINATION = Path(__file__).resolve().parents[1] / "assets/models/docaligner_fastvit_sa24_7f9f5a89.onnx"
API_URL = f"https://api.github.com/repos/{REPOSITORY}/releases/tags/{RELEASE_TAG}"


def request(url: str, *, accept: str = "application/vnd.github+json"):
    req = urllib.request.Request(
        url,
        headers={"Accept": accept, "User-Agent": "Scan-id-pinned-model-fetch/1.0"},
    )
    return urllib.request.urlopen(req, timeout=60)


def main() -> int:
    try:
        with request(API_URL) as response:
            release = json.load(response)
        if release.get("tag_name") != RELEASE_TAG:
            raise RuntimeError(f"unexpected upstream release tag: {release.get('tag_name')!r}")
        assets = [asset for asset in release.get("assets", []) if asset.get("name") == ASSET_NAME]
        if len(assets) != 1:
            raise RuntimeError(f"expected one upstream asset named {ASSET_NAME!r}; found {len(assets)}")
        asset = assets[0]
        if (
            asset.get("id") != ASSET_ID
            or asset.get("size") != EXPECTED_BYTES
            or asset.get("digest") != f"sha256:{EXPECTED_SHA256}"
        ):
            raise RuntimeError(
                "upstream GitHub Release metadata no longer matches the pinned "
                f"asset id/size/digest: id={asset.get('id')}, size={asset.get('size')}, "
                f"digest={asset.get('digest')}"
            )

        DESTINATION.parent.mkdir(parents=True, exist_ok=True)
        if DESTINATION.exists():
            digest = hashlib.sha256()
            size = 0
            with DESTINATION.open("rb") as existing:
                for block in iter(lambda: existing.read(1024 * 1024), b""):
                    size += len(block)
                    digest.update(block)
            if size != EXPECTED_BYTES or digest.hexdigest() != EXPECTED_SHA256:
                raise RuntimeError(
                    f"refusing to overwrite existing unverified model file {DESTINATION} "
                    f"(size={size}, sha256={digest.hexdigest()})"
                )
            print(
                f"Verified existing DocAligner asset: release={RELEASE_TAG} "
                f"asset_id={ASSET_ID} bytes={size} sha256={digest.hexdigest()}"
            )
            return 0

        fd, temporary_name = tempfile.mkstemp(
            prefix=".docaligner-", suffix=".download", dir=DESTINATION.parent
        )
        os.close(fd)
        temporary = Path(temporary_name)
        try:
            digest = hashlib.sha256()
            size = 0
            with request(asset["browser_download_url"], accept="application/octet-stream") as response:
                with temporary.open("wb") as output:
                    while block := response.read(1024 * 1024):
                        size += len(block)
                        if size > EXPECTED_BYTES:
                            raise RuntimeError("download exceeded the pinned model size")
                        digest.update(block)
                        output.write(block)
            actual_digest = digest.hexdigest()
            if size != EXPECTED_BYTES or actual_digest != EXPECTED_SHA256:
                raise RuntimeError(
                    f"downloaded model verification failed: bytes={size}, sha256={actual_digest}"
                )
            os.replace(temporary, DESTINATION)
            print(
                f"Downloaded and verified DocAligner asset: release={RELEASE_TAG} "
                f"asset_id={ASSET_ID} bytes={size} sha256={actual_digest}"
            )
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
        return 0
    except Exception as error:  # CI needs a concise non-secret failure reason.
        print(f"DocAligner model preparation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
