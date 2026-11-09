#!/usr/bin/env python3
"""Fetch and verify the pinned Windows x64 native build archives (PDFium & ONNX Runtime).

This is a build/CI preparation tool only; the application itself never
downloads anything at runtime (ADR-005). Every archive is pinned by GitHub
Release tag, asset ID, byte size, and SHA-256, and verified before atomic
placement into `.dart_tool/windows-native-cache/`.
"""

from __future__ import annotations

import hashlib
import os
import sys
import tempfile
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE_DIR = ROOT / ".dart_tool" / "windows-native-cache"


@dataclass(frozen=True)
class ReleaseAsset:
    repository: str
    release_tag: str
    asset_id: int
    filename: str
    cache_name: str
    size: int
    sha256: str

    @property
    def api_asset_url(self) -> str:
        return f"https://api.github.com/repos/{self.repository}/releases/assets/{self.asset_id}"

    @property
    def browser_download_url(self) -> str:
        return (
            f"https://github.com/{self.repository}/releases/download/"
            f"{self.release_tag}/{self.filename}"
        )

    @property
    def destination(self) -> Path:
        return CACHE_DIR / self.cache_name


ASSETS = (
    ReleaseAsset(
        repository="bblanchon/pdfium-binaries",
        release_tag="chromium/8086",
        asset_id=613146057,
        filename="pdfium-win-x64.tgz",
        cache_name="pdfium-win-x64-8086.tgz",
        size=3_866_531,
        sha256="1fd8af952832dbb0eb16d9249f68fe09e5f5ebf7c3dd9f6066ea2720cc28487d",
    ),
    ReleaseAsset(
        repository="microsoft/onnxruntime",
        release_tag="v1.28.3",
        asset_id=604067913,
        filename="onnxruntime-win-x64-1.28.3.zip",
        cache_name="onnxruntime-win-x64-1.28.3.zip",
        size=78_606_946,
        sha256="1d6fab48e85f948436af7c8c971d2c145cf224e2c444755dec894f8b0de11a83",
    ),
)


def digest_file(path: Path) -> tuple[int, str]:
    sha = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            size += len(block)
            sha.update(block)
    return size, sha.hexdigest()


def verify(asset: ReleaseAsset) -> bool:
    if not asset.destination.is_file():
        return False
    size, sha = digest_file(asset.destination)
    if size != asset.size or sha != asset.sha256:
        asset.destination.unlink(missing_ok=True)
        return False
    print(
        f"Verified cached {asset.cache_name}: bytes={size} sha256={sha} "
        f"source={asset.repository}@{asset.release_tag}"
    )
    return True


def open_asset_stream(asset: ReleaseAsset):
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    urls = [asset.api_asset_url, asset.browser_download_url] if token else [asset.browser_download_url, asset.api_asset_url]
    last_error: Exception | None = None
    for url in urls:
        req = urllib.request.Request(
            url,
            headers={
                "Accept": "application/octet-stream",
                "User-Agent": "Scan-id-pinned-native-fetch/1.0",
            },
        )
        if token and url.startswith("https://api.github.com/"):
            # Unredirected header: sent to api.github.com only, never forwarded
            # to the signed release-assets.githubusercontent.com redirect URL.
            req.add_unredirected_header("Authorization", f"Bearer {token}")
        try:
            return urllib.request.urlopen(req, timeout=180)
        except Exception as error:  # noqa: BLE001
            last_error = error
    assert last_error is not None
    raise last_error


def fetch_with_retries(asset: ReleaseAsset, attempts: int = 5) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        fd, temp_name = tempfile.mkstemp(
            prefix=f".{asset.cache_name}.", suffix=".part", dir=CACHE_DIR
        )
        os.close(fd)
        temp_path = Path(temp_name)
        try:
            print(
                f"Fetching {asset.repository}@{asset.release_tag}/{asset.filename} "
                f"(attempt {attempt}/{attempts})"
            )
            sha = hashlib.sha256()
            size = 0
            with open_asset_stream(asset) as response, temp_path.open("wb") as out:
                while block := response.read(1024 * 1024):
                    size += len(block)
                    if size > asset.size:
                        raise RuntimeError(
                            f"download exceeded pinned size ({size} > {asset.size})"
                        )
                    sha.update(block)
                    out.write(block)
            actual_sha = sha.hexdigest()
            if size != asset.size or actual_sha != asset.sha256:
                raise RuntimeError(
                    f"downloaded bytes do not match pin for {asset.cache_name}: "
                    f"size={size} (expected {asset.size}), "
                    f"sha256={actual_sha} (expected {asset.sha256})"
                )
            os.replace(temp_path, asset.destination)
            print(
                f"Stored verified {asset.destination}: bytes={size} sha256={actual_sha}"
            )
            return
        except Exception as error:  # noqa: BLE001
            last_error = error
            reason = " ".join(str(error).split())[:300]
            print(
                f"Attempt {attempt}/{attempts} failed for {asset.cache_name}: {reason}",
                file=sys.stderr,
            )
            if attempt < attempts:
                time.sleep(attempt * 5)
        finally:
            temp_path.unlink(missing_ok=True)
    raise RuntimeError(f"failed to fetch {asset.cache_name} after {attempts} attempts: {last_error}")


def main() -> int:
    try:
        for asset in ASSETS:
            if verify(asset):
                continue
            fetch_with_retries(asset)
            if not verify(asset):
                raise RuntimeError(f"verified archive still missing: {asset.destination}")
        return 0
    except Exception as error:  # noqa: BLE001
        reason = " ".join(str(error).split())[:500]
        print(f"Windows native dependency preparation failed: {reason}", file=sys.stderr)
        print(f"::error title=windows-native-deps::{reason}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
