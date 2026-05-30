#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def find_repo_root() -> Path:
    script_path = Path(__file__).resolve()
    candidates = [
        script_path.parents[1],
        Path.cwd().resolve(),
        Path.cwd().resolve().parent,
    ]
    for candidate in candidates:
        if (candidate / "tools" / "latency_bench" / "fpga_bins.py").exists():
            return candidate
    return script_path.parents[1]


sys.path.insert(0, str(find_repo_root()))

from tools.latency_bench.fpga_bins import list_fpga_bin_aliases, resolve_fpga_bin_config  # noqa: E402


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Resolve a Vortex FPGA bin alias.")
    parser.add_argument("fpga_bin", nargs="?", help="Alias, bin directory, or vortex_afu.xclbin path.")
    parser.add_argument("--alias-map", default=None, help="Path to ci/fpga_bin_alias_map.yaml.")
    parser.add_argument("--xrt-mem-map", choices=["legacy", "remap"], default=None)
    parser.add_argument("--list", action="store_true", help="Print available aliases and exit.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.list:
        print(", ".join(list_fpga_bin_aliases(args.alias_map)))
        return 0
    if not args.fpga_bin:
        raise SystemExit("fpga_bin is required unless --list is used")

    config = resolve_fpga_bin_config(
        args.fpga_bin,
        xrt_mem_map=args.xrt_mem_map,
        alias_map_path=args.alias_map,
    )
    print(config.path)
    print(" ".join(config.configs_extra))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
