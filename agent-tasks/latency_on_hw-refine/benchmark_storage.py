"""Measure equivalent expanded suite storage, using a fresh process per format.

Run with the repository's Python environment. Outputs are written to a new
directory; input suites are never modified.
"""
from __future__ import annotations

import argparse
import json
import resource
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.latency_bench.suite_io import read_suite_payload, write_suite_payload
from tools.latency_bench.suite import load_suite


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--worker", choices=("yaml", "pkl", "read"))
    args = parser.parse_args()
    if args.worker:
        started = time.perf_counter()
        payload = read_suite_payload(args.input)
        read_s = time.perf_counter() - started
        started = time.perf_counter()
        if args.worker != "read":
            write_suite_payload(args.out, payload)
        write_s = time.perf_counter() - started
        print(json.dumps({"read_s": read_s, "write_s": write_s, "case_count": len(payload["cases"]),
                          "peak_rss_kib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                          "bytes": (args.input if args.worker == "read" else args.out).stat().st_size}))
        return
    args.out.mkdir(parents=True, exist_ok=False)
    results = {"input": str(args.input.resolve()), "python": sys.version}
    for fmt in ("yaml", "pkl"):
        dest = args.out / f"suite.{fmt}"
        command = [sys.executable, __file__, str(args.input), str(dest), "--worker", fmt]
        results[f"write_{fmt}"] = json.loads(subprocess.check_output(command, text=True))
        results[f"read_{fmt}"] = json.loads(subprocess.check_output([sys.executable, __file__, str(dest), str(dest), "--worker", "read"], text=True))
    suites = [load_suite(args.out / f"suite.{fmt}") for fmt in ("yaml", "pkl")]
    assert suites[0].cases == suites[1].cases
    assert suites[0].defaults == suites[1].defaults
    assert suites[0].experiment == suites[1].experiment
    results["semantic_parity"] = True
    results["case_count"] = len(suites[0].cases)
    results["execution_count"] = len({case.exec_key for case in suites[0].cases if case.measurement_kind == "measured"})
    (args.out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
