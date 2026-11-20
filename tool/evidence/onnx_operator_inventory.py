#!/usr/bin/env python3
"""Inventory the ONNX/ORT operators each shipped model actually requires.

Reads the graph, not a manifest: `OrtFormatModelProcessor` walks the ORT-format
model's nodes and `onnx` walks an `.onnx` model's nodes, and the union is what a
Reduced Operator Build must contain.

Three of the four models are NOT committed (they are .gitignore'd and fetched by
tool/fetch_ocr_models.py and tool/fetch_docaligner_model.py). When a model is
absent this script says so and computes the union over what is present, so the
report can never present a partial inventory as a complete one.

Usage:
    python tool/evidence/onnx_operator_inventory.py [--json out.json]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

MODELS = [
    ("DocQuadNet-256", "assets/models/docquadnet256_trained_opset17.ort", "ort"),
    (
        "DocAligner FastViT-SA24",
        "assets/models/docaligner_fastvit_sa24_7f9f5a89.onnx",
        "onnx",
    ),
    ("PP-OCRv5 det", "assets/models/ppocrv5_mobile_det.onnx", "onnx"),
    ("PP-OCRv5 arabic rec", "assets/models/ppocrv5_arabic_mobile_rec.onnx", "onnx"),
]


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            sha.update(block)
    return sha.hexdigest()


def read_ort(path: Path):
    from onnxruntime.tools.ort_format_model import (
        OperatorTypeUsageManager,
        OrtFormatModelProcessor,
    )

    required: dict = {}
    OrtFormatModelProcessor(str(path), required, OperatorTypeUsageManager()).process()
    operators = []
    for domain, opsets in required.items():
        for opset, names in sorted(opsets.items()):
            for name in sorted(names):
                operators.append({"domain": domain, "opset": opset, "op": name})
    return operators


def read_onnx(path: Path):
    import onnx

    model = onnx.load(str(path), load_external_data=False)
    operators = []
    for node in model.graph.node:
        operators.append(
            {
                "domain": node.domain or "ai.onnx",
                "opset": None,
                "op": node.op_type,
            }
        )
    return operators


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json")
    arguments = parser.parse_args()

    report = {"models": [], "union": [], "missing": []}
    for name, relative, kind in MODELS:
        path = ROOT / relative
        entry = {"name": name, "path": relative, "kind": kind}
        if not path.is_file():
            entry["status"] = "ABSENT"
            report["missing"].append(name)
            report["models"].append(entry)
            print(f"ABSENT  {name:26s} {relative}")
            continue
        entry["status"] = "PRESENT"
        entry["bytes"] = path.stat().st_size
        entry["sha256"] = digest(path)
        entry["operators"] = read_ort(path) if kind == "ort" else read_onnx(path)
        report["models"].append(entry)
        unique = sorted({(o["domain"], o["op"]) for o in entry["operators"]})
        print(f"PRESENT {name:26s} {entry['bytes']:,} B  "
              f"{len(unique)} unique ops, {len(entry['operators'])} nodes")

    union = {}
    for entry in report["models"]:
        for operator in entry.get("operators", []):
            key = (operator["domain"], operator["op"])
            union.setdefault(key, set()).add(entry["name"])
    report["union"] = [
        {"domain": domain, "op": op, "requiredBy": sorted(users)}
        for (domain, op), users in sorted(union.items())
    ]

    print()
    print(f"UNION over present models: {len(report['union'])} operators")
    for row in report["union"]:
        print(f"   {row['domain']:14s} {row['op']:24s} "
              f"<- {', '.join(row['requiredBy'])}")
    if report["missing"]:
        print()
        print("INCOMPLETE UNION. Absent models:", ", ".join(report["missing"]))
        print("A Reduced Operator Build must not be attempted from this list.")
        report["complete"] = False
    else:
        report["complete"] = True

    if arguments.json:
        Path(arguments.json).write_text(json.dumps(report, indent=2) + "\n")
        print(f"wrote {arguments.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
