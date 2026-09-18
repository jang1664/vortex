"""Index-based entry points shared by the hardware measurement wrappers."""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parents[1]))

from tools.latency_bench.suite_io import indexed_suites


def _suite_entries(input_root: Path, stage: str) -> list[tuple[str, Path]]:
    merged = input_root / f"{stage}_merged"
    index = merged / "index.yaml"
    if index.is_file():
        return indexed_suites(index)

    prefix = f"{stage}_merged_"
    suites = sorted(merged.glob(f"{prefix}*.yaml"))
    if not suites:
        raise ValueError(
            f"no merged suites found for {stage}: {merged}/{prefix}*.yaml"
        )
    return [
        (suite.name[len(prefix):-len(".yaml")], suite.resolve())
        for suite in suites
    ]


def main(argv: list[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments and arguments[0] in ("pipeline", "status"):
        from pipeline import cli_main

        return cli_main(arguments)
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("run", "suite"))
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--stage", default="prefill")
    parser.add_argument("--label")
    args, extra = parser.parse_known_args(arguments)
    stages = os.environ.get("STAGES", "prefill generation").split() if args.action == "run" else [args.stage]
    selected = os.environ.get("FPGA_BINS", "").split()
    jobs = []
    for stage in stages:
        if stage not in ("prefill", "generation"):
            raise ValueError(f"unsupported stage: {stage}")
        entries = _suite_entries(args.input, stage)
        labels = [label for label, _ in entries]
        if len(labels) != len(set(labels)):
            raise ValueError(f"duplicate execution bins for {stage}")
        if args.action == "suite":
            matches = [path for label, path in entries if label == args.label]
            if len(matches) != 1:
                raise ValueError(f"expected one suite for {stage}/{args.label}")
            print(matches[0])
            return 0
        if set(selected) - set(labels):
            raise ValueError(f"requested bins absent from {stage} index: {set(selected) - set(labels)}")
        jobs.extend((stage, label, path) for label, path in entries if not selected or label in selected)
    if args.output is None:
        parser.error("run requires --output")
    for stage, label, path in jobs:
        env = dict(os.environ, STAGE=stage, SUITE=str(path), OUT_DIR=str(args.output / label))
        print(f"STAGE={stage} FPGA_BIN={label} SUITE={path} OUT_DIR={env['OUT_DIR']}", flush=True)
        subprocess.run([str(SCRIPT_DIR / "run_fpga_bin.sh"), label, *extra], env=env, check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
