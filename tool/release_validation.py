#!/usr/bin/env python3
"""
Validation logic for release management - shared between dashboard JS and Workflow Python.
Implements strict SemVer 2.0.0 parsing identical to Dart _SemVersion.parse
and build number / duplicate checks.
"""
import re

SEMVER_RE = re.compile(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$'
)

def parse_semver(v: str):
    m = SEMVER_RE.match(v)
    if not m:
        return None
    prerelease = m.group(4).split('.') if m.group(4) else []
    for ident in prerelease:
        if re.match(r'^[0-9]+$', ident) and len(ident) > 1 and ident.startswith('0'):
            return None
    return {
        'major': int(m.group(1)),
        'minor': int(m.group(2)),
        'patch': int(m.group(3)),
        'prerelease': prerelease,
        'build': m.group(5) or '',
        'core': f"{m.group(1)}.{m.group(2)}.{m.group(3)}",
    }

def compare_semver(a: str, b: str) -> int:
    pa, pb = parse_semver(a), parse_semver(b)
    if not pa or not pb:
        raise ValueError(f"Invalid SemVer: {a if not pa else b}")
    for k in ['major','minor','patch']:
        if pa[k] != pb[k]:
            return 1 if pa[k] > pb[k] else -1
    pra, prb = pa['prerelease'], pb['prerelease']
    if not pra and not prb:
        return 0
    if not pra:
        return 1
    if not prb:
        return -1
    for x,y in zip(pra, prb):
        nx, ny = x.isdigit(), y.isdigit()
        if nx and ny:
            if len(x) != len(y):
                return 1 if len(x) > len(y) else -1
            if x != y:
                return 1 if x > y else -1
        elif nx != ny:
            return -1 if nx else 1
        else:
            if x != y:
                return 1 if x > y else -1
    return len(pra) - len(prb)

def extract_version(tag: str):
    v = tag
    if v.startswith('v'):
        v = v[1:]
    if v.startswith('release-'):
        v = v[len('release-'):]
    return v if parse_semver(v) else None

def validate_release_request(new_version: str, new_build: str, release_notes: str, targets: str,
                            current_core: str, current_build: str,
                            last_release_tag: str, existing_tags: list, concurrent_runs: int = 0):
    errors = []
    # SemVer
    if not parse_semver(new_version):
        errors.append(f"صيغة الإصدار غير صالحة: {new_version}")
    else:
        try:
            if compare_semver(new_version, current_core) <= 0:
                errors.append(f"الإصدار الجديد {new_version} ليس أحدث من الحالي {current_core}")
            if last_release_tag:
                last_ver = extract_version(last_release_tag)
                if last_ver and compare_semver(new_version, last_ver) <= 0:
                    errors.append(f"الإصدار الجديد {new_version} ليس أحدث من آخر Release {last_release_tag}")
        except ValueError as e:
            errors.append(str(e))
    # Duplicate tag
    tag = f"v{new_version}"
    if tag in existing_tags:
        errors.append(f"Tag {tag} موجود مسبقاً")
    # Build number
    if not re.match(r'^[0-9]+$', new_build) or int(new_build) < 1:
        errors.append(f"رقم البناء يجب أن يكون عدداً موجباً: {new_build}")
    elif new_version == current_core and int(new_build) <= int(current_build or 0):
        errors.append(f"رقم البناء {new_build} يجب أن يكون أكبر من الحالي {current_build} لنفس Core")
    # Notes
    if not release_notes or len(release_notes) < 3:
        errors.append("ملاحظات قصيرة جداً")
    if len(release_notes) > 5000:
        errors.append("ملاحظات طويلة جداً")
    # Targets
    if targets not in ['both','android','windows']:
        errors.append(f"الأنظمة المستهدفة غير صالحة: {targets}")
    # Concurrent
    if concurrent_runs > 0:
        errors.append("يوجد نشر متزامن")
    return errors

if __name__ == "__main__":
    import sys, json
    # Simple CLI for testing
    print(compare_semver("0.1.1","0.1.0"))  # 1
    print(parse_semver("0.1.0+1"))
