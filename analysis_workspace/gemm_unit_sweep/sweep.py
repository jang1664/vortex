"""Sweep VX_gemm_unit synthesis over (WLOAD_AT_ONCE, MXU_COL_TILE).

For each (wonce ∈ {off, on}) × (col_tile ∈ {1, 2, 4, 8, 16, 32}) point this
script invokes `hw/syn/synopsys/gemm_unit_breakdown/scripts/run.py` with
matching `--extra-define` flags and a distinct `--syn-dir` so the 12 runs
land in sibling directories under
    build/hw/syn/synopsys/gemm_unit_breakdown/syn/run/v0/

Each synth run takes ~tens of minutes; the whole sweep is hours. The script
runs serially by default. Skipped points (already-present `reports/14_*.area.rpt`)
are not re-run unless --rerun is given.

Run from a Python with hwexplorer installed:
    conda activate stable
    python analysis_workspace/gemm_unit_sweep/sweep.py [--dry-run] [--rerun]
                                                      [--period-ns 5.0]
                                                      [--only-wonce on|off]
                                                      [--only-col-tile 4]
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import shlex
import subprocess
import sys
from itertools import product
from pathlib import Path

HERE = Path(__file__).resolve().parent
VORTEX = HERE.parents[1]
RUN_PY = VORTEX / "hw/syn/synopsys/gemm_unit_breakdown/scripts/run.py"
BUILD_RUN_DIR = VORTEX / "build/hw/syn/synopsys/gemm_unit_breakdown/syn/run/v0"

WONCE_VALUES = ["off", "on"]
COL_TILE_VALUES = [1, 8, 16, 32]
DEFAULT_PERIOD_NS = 10.0


def period_tag(period_ns: float) -> str:
    return f"p{period_ns:g}ns".replace(".", "p").replace("-", "m")


def syn_dir_for(wonce: str, col_tile: int, period_ns: float) -> str:
    base = f"syn_topo_wonce_{wonce}_col{col_tile}.run1"
    if period_ns == DEFAULT_PERIOD_NS:
        return base
    return f"{base}_{period_tag(period_ns)}"


def expected_area_rpt(syn_dir: str) -> Path:
    return BUILD_RUN_DIR / syn_dir / "reports" / "14_VX_gemm_unit_top.mapped.area.rpt"


def defines_for(wonce: str, col_tile: int) -> list[str]:
    defines = [f"MXU_COL_TILE={col_tile}"]
    if wonce == "on":
        defines.append("WLOAD_AT_ONCE")
    return defines


def run_point(wonce: str, col_tile: int, *, period_ns: float, dry_run: bool,
              rerun: bool, log_dir: Path) -> tuple[str, int]:
    syn_dir = syn_dir_for(wonce, col_tile, period_ns)
    rpt = expected_area_rpt(syn_dir)
    if rpt.exists() and not rerun:
        return ("skipped", 0)

    cmd = [
        sys.executable, str(RUN_PY),
        "--syn-dir", syn_dir,
        "--period-ns", f"{period_ns:g}",
    ]
    for d in defines_for(wonce, col_tile):
        cmd += ["--extra-define", d]

    print(f"[sweep] >>> {syn_dir}")
    print(f"        cmd: {shlex.join(cmd)}")
    if dry_run:
        return ("dry-run", 0)

    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / f"{syn_dir}.log"
    with log_path.open("w") as logf:
        logf.write(f"# {dt.datetime.now().isoformat(timespec='seconds')}\n")
        logf.write(f"# cmd: {shlex.join(cmd)}\n\n")
        logf.flush()
        ret = subprocess.call(cmd, stdout=logf, stderr=subprocess.STDOUT,
                              cwd=str(VORTEX))
    status = "ok" if ret == 0 else f"fail ({ret})"
    print(f"[sweep] <<< {syn_dir}: {status}  log={log_path}")
    return (status, ret)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                    help="Print commands but do not run synth.")
    ap.add_argument("--rerun", action="store_true",
                    help="Re-synthesize points whose area report already exists.")
    ap.add_argument("--only-wonce", choices=WONCE_VALUES,
                    help="Restrict sweep to a single WLOAD_AT_ONCE state.")
    ap.add_argument("--only-col-tile", type=int,
                    help="Restrict sweep to a single MXU_COL_TILE value.")
    ap.add_argument("--period-ns", type=float, default=DEFAULT_PERIOD_NS,
                    help="Clock period in ns forwarded to synthesis run.py. "
                    "Non-default periods get distinct syn_dir suffixes.")
    args = ap.parse_args()

    wonces = [args.only_wonce] if args.only_wonce else WONCE_VALUES
    cols = [args.only_col_tile] if args.only_col_tile else COL_TILE_VALUES

    log_dir = HERE / "logs"
    summary = []
    for wonce, col in product(wonces, cols):
        status, ret = run_point(wonce, col, period_ns=args.period_ns,
                                dry_run=args.dry_run,
                                rerun=args.rerun, log_dir=log_dir)
        summary.append((wonce, col, status, ret))

    print(f"\n[sweep] summary: period_ns={args.period_ns:g}")
    for wonce, col, status, _ in summary:
        print(f"  wonce={wonce:>3}  col_tile={col:>2}  -> {status}")

    n_fail = sum(1 for *_, r in summary if r != 0 and summary != "skipped")
    sys.exit(1 if n_fail else 0)


if __name__ == "__main__":
    main()
