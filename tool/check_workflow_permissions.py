#!/usr/bin/env python3
"""Static least-privilege guard for repository GitHub Actions workflows.

The checker intentionally has no YAML dependency. It validates the specific
permission boundaries and write-capable paths that must remain explicit.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def workflow_level_permissions(source: str) -> str:
    match = re.search(
        r"(?m)^permissions:\s*\n((?:^[ \t]+[^\n]*\n)*)",
        source,
    )
    return match.group(1) if match else ""


def job_block(source: str, job: str) -> str:
    match = re.search(
        rf"(?m)^  {re.escape(job)}:\s*\n(.*?)(?=^  [A-Za-z0-9_-]+:\s*$|\Z)",
        source,
        re.S,
    )
    return match.group(1) if match else ""


def verify() -> list[str]:
    failures: list[str] = []

    allowed_write_jobs = {
        ("cleanup-old-runs.yml", "cleanup"),
        ("android-signed-release.yml", "publish-release"),
        ("release-management.yml", "publish"),
    }
    for workflow_path in sorted(WORKFLOWS.glob("*.yml")):
        source = workflow_path.read_text(encoding="utf-8")
        permissions = workflow_level_permissions(source)
        if not permissions:
            failures.append(f"{workflow_path.name} must declare explicit workflow-level permissions.")
        if re.search(r"(?m)^\s+[A-Za-z0-9_-]+:\s*write\s*$", permissions):
            failures.append(f"{workflow_path.name} must not grant workflow-wide write permissions.")
        job_names = re.findall(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", source.split("jobs:", 1)[-1])
        for job_name in job_names:
            block = job_block(source, job_name)
            job_permissions = re.search(r"(?m)^    permissions:\s*\n((?:^      [^\n]*\n)*)", block)
            if job_permissions and re.search(r"(?m)^      [A-Za-z0-9_-]+:\s*write\s*$", job_permissions.group(1)):
                if (workflow_path.name, job_name) not in allowed_write_jobs:
                    failures.append(f"{workflow_path.name}:{job_name} has an unapproved job-level write permission.")

    verify_wf = text(".github/workflows/verify.yml")
    verify_perms = workflow_level_permissions(verify_wf)
    if "contents: read" not in verify_perms or "contents: write" in verify_perms:
        failures.append("verify.yml must use workflow-level contents: read only.")
    if "git push" in verify_wf or "git commit" in verify_wf or "SCAN_ID_FORMAT_COMMIT" in verify_wf:
        failures.append("verify.yml must not contain a commit/push formatter path.")
    if "test.tool.test_local_annotation_validator" not in verify_wf or "test.tool.test_format_report" not in verify_wf or "node --check" not in verify_wf:
        failures.append("verify.yml must test local privacy tooling and annotation-studio syntax.")
    format_script = text("tool/format_report.py")
    if re.search(r"subprocess\.[^(]+\([^)]*['\"]git['\"]", format_script):
        failures.append("tool/format_report.py must remain a read-only formatter gate.")
    if '"dart", "format", "--output=none", "--set-exit-if-changed", "."' not in format_script:
        failures.append("formatter helper must execute the official read-only dart format command.")

    cleanup_wf = text(".github/workflows/cleanup-old-runs.yml")
    cleanup_perms = workflow_level_permissions(cleanup_wf)
    cleanup_job = job_block(cleanup_wf, "cleanup")
    if any(f"{scope}: write" in cleanup_perms for scope in ("actions", "contents")):
        failures.append("cleanup write permissions must not be workflow-wide.")
    if "actions: write" not in cleanup_job or "contents: write" not in cleanup_job:
        failures.append("cleanup job must scope its required deletion permissions to that job.")
    if "github.event.repository.default_branch" not in cleanup_job:
        failures.append("live cleanup must be guarded to the repository default branch.")
    cleanup_code = text("tool/branch_cleanup.py")
    if re.search(r'run\(\s*\[\s*["\']git["\']\s*,\s*["\']push["\']', cleanup_code):
        failures.append("branch cleanup must not fall back to git push for deletion.")

    signed_wf = text(".github/workflows/android-signed-release.yml")
    signed_perms = workflow_level_permissions(signed_wf)
    signed_publish = job_block(signed_wf, "publish-release")
    signed_build = job_block(signed_wf, "android-signed-release")
    if "contents: read" not in signed_perms or "contents: write" in signed_perms:
        failures.append("signed-release workflow defaults must remain read-only.")
    if "contents: write" not in signed_publish or "github.event.repository.default_branch" not in signed_publish:
        failures.append("release write access must be isolated to a default-branch publish job.")
    if "github.event.repository.default_branch" not in signed_build:
        failures.append("signing secrets must only be available on the default branch.")

    release_wf = text(".github/workflows/release-management.yml")
    release_perms = workflow_level_permissions(release_wf)
    release_publish = job_block(release_wf, "publish")
    validate_job = job_block(release_wf, "validate")
    if "contents: read" not in release_perms or "contents: write" in release_perms:
        failures.append("release-management workflow defaults must remain read-only.")
    if "contents: write" not in release_publish or "github.event.repository.default_branch" not in release_publish:
        failures.append("release-management write access must be confined to default-branch publish.")
    if "secrets.RELEASE_TOKEN" in validate_job or "github.token" not in validate_job:
        failures.append("read-only release validation must use GITHUB_TOKEN, not the release PAT.")
    if "secrets.RELEASE_TOKEN" in release_wf.split("  publish:", 1)[0]:
        failures.append("the release PAT must not enter validation, versioning, build, or Windows jobs.")
    for job in ("validate", "update-version", "build", "windows"):
        if "github.event.repository.default_branch" not in job_block(release_wf, job):
            failures.append(f"release-management job {job!r} must be default-branch-only.")

    windows_wf = text(".github/workflows/windows-release.yml")
    if "contents: read" not in workflow_level_permissions(windows_wf) or "contents: write" in workflow_level_permissions(windows_wf):
        failures.append("reusable Windows build workflow must be read-only.")

    annotation_tool = text("tool/local_annotation_studio.html")
    if "connect-src 'none'" not in annotation_tool or "<script src=" in annotation_tool or "<link " in annotation_tool:
        failures.append("local annotation studio must have a self-contained, network-blocked CSP.")
    if any(token in annotation_tool for token in ("fetch(", "XMLHttpRequest", "WebSocket(", "sendBeacon(", "Mostmskat/")):
        failures.append("local annotation studio must not upload, contact a service, or hard-code a private corpus path.")
    if "crypto.subtle.digest('SHA-256'" not in annotation_tool or "URL.createObjectURL(blob)" not in annotation_tool:
        failures.append("local annotation studio must use local content IDs and explicit local JSON export.")

    return failures


def main() -> int:
    failures = verify()
    if failures:
        print("FAIL: workflow permission audit:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("PASS: verification is read-only; release and cleanup writes are isolated to guarded jobs; no formatter or branch-deletion git-push path remains.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
