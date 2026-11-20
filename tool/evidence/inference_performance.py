#!/usr/bin/env python3
"""Measure DocQuadNet session cost, inference latency and memory on CPU.

Scope and honesty boundaries, stated because they decide how far these numbers
transfer:

* This runs the REAL bundled graph (`assets/models/docquadnet256_trained_opset17.ort`)
  through ONNX Runtime's CPU provider. It is not a phone and not the Flutter
  plugin: it measures the graph, the runtime's session creation, and the
  allocation the graph forces.
* It does NOT measure `flutter_onnxruntime` channel overhead, Android ART, the
  Dart UI isolate, or device thermal throttling. Those need a device.
* Peak memory uses `resource.getrusage` for the process, so it includes the
  Python interpreter, numpy and PIL as a constant baseline. The delta between
  the idle and post-run figures is the meaningful part.

Usage:
    python tool/evidence/inference_performance.py [--json out.json]
"""

from __future__ import annotations

import argparse
import gc
import json
import platform
import resource
import statistics
import sys
import time
from pathlib import Path

try:
    import numpy as np
    import onnxruntime as ort
except ImportError as error:  # pragma: no cover - tooling only
    print(f"missing measurement dependency: {error}", file=sys.stderr)
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parents[2]
MODEL = ROOT / "assets/models/docquadnet256_trained_opset17.ort"

# The app opens its sessions with intraOpNumThreads: 2 (docquad_model.dart).
APP_THREADS = 2
WARMUP = 5
TRIALS = 30


def rss_mib() -> float:
    # Linux reports ru_maxrss in kilobytes.
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024


def current_rss_mib() -> float:
    status = Path("/proc/self/status").read_text()
    for line in status.splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1]) / 1024
    return float("nan")


def session_time(options=None) -> float:
    started = time.perf_counter()
    ort.InferenceSession(str(MODEL), sess_options=options,
                         providers=["CPUExecutionProvider"])
    return (time.perf_counter() - started) * 1000


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json")
    arguments = parser.parse_args()

    gc.collect()
    idle_rss = current_rss_mib()
    peak_before = rss_mib()

    # Session creation, cold and then repeated, with the app's thread count.
    options = ort.SessionOptions()
    options.intra_op_num_threads = APP_THREADS
    cold_ms = session_time(options)
    repeat = [session_time(options) for _ in range(5)]
    session = ort.InferenceSession(str(MODEL), sess_options=options,
                                   providers=["CPUExecutionProvider"])

    after_session_rss = current_rss_mib()
    peak_after_session = rss_mib()

    tensor = np.zeros((1, 3, 256, 256), dtype=np.float32)
    for _ in range(WARMUP):
        session.run(None, {"input": tensor})

    latencies = []
    for _ in range(TRIALS):
        started = time.perf_counter()
        session.run(None, {"input": tensor})
        latencies.append((time.perf_counter() - started) * 1000)

    # Sustained sequential processing: is there a leak across many images?
    # Reported as first-block vs last-block latency because a native leak most
    # often shows up as growth rather than as a single slow call.
    block_timings = []
    for _block in range(5):
        block_started = time.perf_counter()
        for _ in range(20):
            session.run(None, {"input": tensor})
        block_timings.append((time.perf_counter() - block_started) * 1000 / 20)
    rss_after_sustained = current_rss_mib()

    del session
    gc.collect()
    after_rss = current_rss_mib()
    peak_total = rss_mib()

    latencies.sort()
    summary = {
        "runtime": ort.__version__,
        "python": platform.python_version(),
        "provider": "CPUExecutionProvider",
        "threads": APP_THREADS,
        "model_bytes": MODEL.stat().st_size,
        "session_create_first_ms": round(cold_ms, 1),
        "session_create_repeat_ms": [round(value, 1) for value in repeat],
        "inference_ms": {
            "trials": TRIALS,
            "min": round(latencies[0], 2),
            "p50": round(statistics.median(latencies), 2),
            "p95": round(latencies[int(len(latencies) * 0.95) - 1], 2),
            "max": round(latencies[-1], 2),
            "mean": round(statistics.fmean(latencies), 2),
        },
        "memory_mib": {
            "idle_rss": round(idle_rss, 1),
            "after_session_rss": round(after_session_rss, 1),
            "session_delta": round(after_session_rss - idle_rss, 1),
            "peak_during_session_load": round(peak_after_session, 1),
            "rss_after_release": round(after_rss, 1),
            "retained_after_release": round(after_rss - idle_rss, 1),
            "peak_total": round(peak_total, 1),
            "peak_delta_over_idle": round(peak_total - idle_rss, 1),
            "rss_after_100_inferences": round(rss_after_sustained, 1),
        },
        "sustained_ms_per_image": [round(value, 2) for value in block_timings],
        "sustained_drift_pct": round(
            100 * (block_timings[-1] - block_timings[0]) / block_timings[0], 1
        ),
        "not_measured": [
            "flutter_onnxruntime platform-channel overhead",
            "Android ART / Dart isolate scheduling",
            "device thermal throttling and sustained throughput",
            "real camera JPEG decode (no device, no corpus in this workspace)",
        ],
    }

    print(f"OR runtime      : {summary['runtime']} ({summary['provider']}, "
          f"{APP_THREADS} threads)")
    print(f"model bytes     : {summary['model_bytes']:,}")
    print(f"session create  : first {cold_ms:.1f} ms, then "
          + ", ".join(f"{value:.1f}" for value in repeat) + " ms")
    print(f"inference       : p50 {latencies[len(latencies)//2]:.2f} ms, "
          f"mean {statistics.fmean(latencies):.2f} ms, "
          f"max {latencies[-1]:.2f} ms over {TRIALS} trials")
    print(f"RSS idle        : {idle_rss:.1f} MiB")
    print(f"RSS + session   : {after_session_rss:.1f} MiB "
          f"(delta {after_session_rss - idle_rss:+.1f} MiB)")
    print(f"RSS after close : {after_rss:.1f} MiB "
          f"(retained {after_rss - idle_rss:+.1f} MiB)")
    print(f"peak RSS        : {peak_total:.1f} MiB "
          f"(delta over idle {peak_total - idle_rss:+.1f} MiB)")
    print(f"sustained       : "
          + ", ".join(f"{value:.2f}" for value in block_timings)
          + " ms/image over 5 blocks of 20 (100 images)")
    print(f"100-image RSS   : {rss_after_sustained:.1f} MiB "
          f"({rss_after_sustained - idle_rss:+.1f} MiB over idle)")

    if arguments.json:
        Path(arguments.json).write_text(json.dumps(summary, indent=2) + "\n")
        print(f"\nwrote {arguments.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
