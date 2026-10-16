#!/usr/bin/env python3
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parents[2] / "tool"))
import release_validation as rv

def check(cond, msg):
    if not cond:
        raise AssertionError(msg)
    print(f"PASS {msg}")

# SemVer
check(rv.parse_semver("0.1.0")["core"]=="0.1.0", "parse 0.1.0")
check(rv.parse_semver("0.1.0-alpha.1") is not None, "prerelease")
check(rv.parse_semver("01.0.0") is None, "leading zero major rejected")
check(rv.parse_semver("0.1.0-alpha.01") is None, "numeric prerelease leading zero")
check(rv.compare_semver("0.1.1","0.1.0")==1, "compare greater")
check(rv.compare_semver("0.1.0","0.1.1")==-1, "compare less")
check(rv.compare_semver("1.0.0","1.0.0-alpha")>0, "release > prerelease")
check(rv.extract_version("v0.1.0")=="0.1.0", "extract v prefix")

# validate
errs = rv.validate_release_request("0.1.0","6","notes ok","both","0.1.0","5","","[]",0)
check(any("ليس أحدث" in e for e in errs), "same core not greater fails")
errs = rv.validate_release_request("0.1.1","6","ok notes xyz","both","0.1.0","5","","[]",0)
check(len([e for e in errs if "أحدث" in e])==0, "newer version ok")
errs = rv.validate_release_request("0.1.1","abc","ok notes xyz","both","0.1.0","5","","[]",0)
check(any("عدداً" in e for e in errs), "bad build number")
errs = rv.validate_release_request("0.1.1","6","ab","both","0.1.0","5","","[]",0)
check(any("قصيرة" in e for e in errs), "short notes")

# duplicate tag
errs = rv.validate_release_request("0.1.1","6","notes ok xyz","both","0.1.0","5","","[\"v0.1.1\"]",0)
check(len(errs)==1 and "موجود" in errs[0], "duplicate tag via string containment - expected fail if tag list passed as string")
# proper list
errs = rv.validate_release_request("0.1.1","6","notes ok xyz","both","0.1.0","5","","v0.1.1",0)
check(any("موجود" in e for e in errs), "duplicate tag exact")

print("ALL TESTS PASS")
