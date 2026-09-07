#!/usr/bin/env python3
"""Add the three complementary overlap layouts to the canonical GEMM runner.

The canonical smoke/overlap/QROW/tail suite covers overlap d0/t0 already.
This wrapper changes only the case list, preserving strict numerical, trace,
artifact and response-slot checking from measure_gemm.py.
"""

import importlib.util
from pathlib import Path


runner_path = Path(__file__).resolve().parents[1] / "measure_gemm.py"
spec = importlib.util.spec_from_file_location("measure_gemm", runner_path)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.CASES = {
    f"overlap_d{qdir}_t{transpose}": (
        f"-m 4 -n 256 -k 256 -q 32 -t {transpose} -d {qdir} -r 1"
    )
    for qdir, transpose in ((0, 1), (1, 0), (1, 1))
}

if __name__ == "__main__":
    raise SystemExit(runner.main())
