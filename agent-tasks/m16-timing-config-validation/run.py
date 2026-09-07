#!/usr/bin/env python3
"""Validate the two exact MXU16 paired-TMEM profiles using the proven harness."""

import argparse
import importlib.util
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tmem-count", type=int, choices=(8, 16), required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location(
        "measure_perf3", root / "agent-tasks/gemm-dependency-register-cuts/measure_perf3.py")
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    runner.CONFIG = root / f"configs/improve_th16_tcol16_m16_t{args.tmem_count}_bigmem.sh"
    sys.argv = [str(spec.origin), "--variant", f"m16_t{args.tmem_count}",
                "--repeat", "1", "--timeout", "300"]
    return runner.main()


if __name__ == "__main__":
    raise SystemExit(main())
