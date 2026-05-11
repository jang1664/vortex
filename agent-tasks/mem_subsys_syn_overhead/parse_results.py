"""Consolidate the per-point area / timing reports into CSVs.

Each SynthConfig run lands at:
  build/hw/syn/synopsys/mem_subsys_syn_overhead/run/<top>/<label>/syn_topo.lpp/reports/

The hwexplorer report parsers (SynopsysDesignCompilerAreaParser /
TimingParser) handle the file format. We pattern-match xbar instance names
per top so the stacked-bar plot can split (xbar / sram / other) area.
"""

from __future__ import annotations

import argparse
import glob
import os
from pathlib import Path

import pandas as pd  # noqa: F401  (lazy: import only if installed at run time)

HERE = Path(__file__).resolve().parent
DEFAULT_VORTEX_HOME = HERE.parents[1]
RUN_ROOT = (DEFAULT_VORTEX_HOME / "build" / "hw" / "syn" / "synopsys"
            / "mem_subsys_syn_overhead" / "run")

LMEM_PATTERNS = [
    (r"^VX_local_mem_top$",          "top"),
    (r".*\bVX_local_mem\b.*req_xbar$", "xbar_req"),
    (r".*\bVX_local_mem\b.*rsp_xbar$", "xbar_rsp"),
    (r".*lmem_store(\..*)?$",         "sram"),
]
CACHE_PATTERNS = [
    (r"^VX_cache_top$",              "top"),
    (r".*core_req_xbar$",            "xbar_core_req"),
    (r".*core_rsp_xbar$",            "xbar_core_rsp"),
    (r".*mem_req_xbar$",             "xbar_mem_req"),
    (r".*mem_rsp_xbar$",             "xbar_mem_rsp"),
    (r".*data_store(\..*)?$",        "data_ram"),
    (r".*tag_store(\..*)?$",         "tag_ram"),
    (r".*mshr_store(\..*)?$",        "mshr_ram"),
]
AXI_PATTERNS = [
    (r"^VX_axi_adapter$",            "top"),
    (r".*req_xbar$",                 "xbar_req"),
    (r".*rsp_xbar$",                 "xbar_rsp"),
]


def _patterns_for(top: str):
    return {
        "VX_local_mem_top": LMEM_PATTERNS,
        "VX_cache_top":     CACHE_PATTERNS,
        "VX_axi_adapter":   AXI_PATTERNS,
    }[top]


def collect():
    rows_area, rows_timing = [], []
    from hwexplorer import report_parser  # type: ignore

    area_p = report_parser.SynopsysDesignCompilerAreaParser()
    tim_p  = report_parser.SynopsysDesignCompilerTimingParser()

    for run_dir in sorted(glob.glob(str(RUN_ROOT / "*" / "*"))):
        top   = Path(run_dir).parent.name
        label = Path(run_dir).name
        rpt_dir = Path(run_dir) / "syn_topo.lpp" / "reports"
        if not rpt_dir.is_dir():
            print(f"[skip] {run_dir}: no reports/ dir")
            continue

        area_rpt = rpt_dir / "report_area.rpt"
        if area_rpt.exists():
            df = area_p.parse(str(area_rpt), _patterns_for(top))
            df["top"] = top
            df["label"] = label
            rows_area.append(df)

        qor_rpt = rpt_dir / "report_qor.rpt"
        if qor_rpt.exists():
            df = tim_p.parse(str(qor_rpt))
            df["top"] = top
            df["label"] = label
            rows_timing.append(df)

    if rows_area:
        out = HERE / "area.csv"
        pd.concat(rows_area).to_csv(out, index=False)
        print(f"[ok] wrote {out}")
    if rows_timing:
        out = HERE / "timing.csv"
        pd.concat(rows_timing).to_csv(out, index=False)
        print(f"[ok] wrote {out}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.parse_args()
    collect()
