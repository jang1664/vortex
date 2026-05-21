"""Extract per-component area + routing-difficulty proxies from synth runs.

Sources:
  build/hw/syn/synopsys/mem_subsys_syn_overhead/run/<top>/<label>/syn_topo.lpp/reports/
    14_*.mapped.area.rpt        - cell area + util + core area
    20_*.mapped.congestion.rpt  - Zroute-virtual congestion + wire length
  build/hw/syn/synopsys/gemm_unit_breakdown/syn/run/v0/syn_topo.run1/reports/14_*

Outputs:
  area.csv     rows {design, label, n, kind, area_um2} (kind ∈ total/xbar/sram/ctrl)
  routing.csv  rows {design, label, n, core_area, util, overflow,
                     overflow_pct, wirelength_um, macro_area, cell_area}

This extractor deliberately emits raw SRAM macro area only. Accounting choices
such as "SRAM peri applies to FPxINT but not to the FPFP baseline" are handled
in plot.py, where the scenario semantics are known.

DC topographical auto-sizes the core to satisfy the optimizer's routability
estimate. Low utilization at high N is therefore a routing-difficulty signal:
DC had to give the design more whitespace to make global route feasible.
Congestion overflow (Zroute's residual overflow GRCs after phase3) is a
direct, unsmoothed routing-pain proxy.

The hierarchical area report column layout (DC topographical) is:
    <inst_path>  <abs_total>  <pct>  <comb>  <noncomb>  <bbox>  <design>
The parent line's "abs_total" already includes every child subtree, so we
match each top-of-xbar / top-of-sram path exactly once.
"""

from __future__ import annotations

import csv
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
VORTEX = HERE.parents[1]
MEM_RUN = VORTEX / "build" / "hw" / "syn" / "synopsys" / "mem_subsys_syn_overhead" / "run"
GEMM_RUN = VORTEX / "build" / "hw" / "syn" / "synopsys" / "gemm_unit_breakdown" / "syn" / "run" / "v0" / "syn_topo.run1"

RE_TOTAL = re.compile(r"^\s*Total cell area:\s+([\d.]+)", re.MULTILINE)
RE_MACRO_AREA = re.compile(r"^\s*Macro/Black Box area:\s+([\d.]+)", re.MULTILINE)
RE_CORE = re.compile(r"^\s*Core Area:\s+([\d.]+)", re.MULTILINE)
RE_UTIL = re.compile(r"^\s*Utilization Ratio:\s+([\d.]+)", re.MULTILINE)
RE_HIER_LINE = re.compile(r"^(\S+)\s+([\d.]+)\s+\d+\.\d+\s+")
# Last "Both Dirs: Overflow = N Max = M (P GRCs) GRCs = Q (X.YY%)" in congestion rpt.
RE_OVF = re.compile(r"Both Dirs:\s+Overflow\s+=\s+(\d+)\s+Max\s+=\s+\d+.*?GRCs\s+=\s+\d+\s+\(([\d.]+)%\)")
RE_WL  = re.compile(r"Total Wire Length\s*=\s*([\d.]+)")

PATTERNS = {
    "VX_local_mem_top": {
        "xbar": [re.compile(r"^local_mem/(req_xbar|rsp_xbar)$")],
        "sram": [re.compile(r"^local_mem/g_data_store_\d+__lmem_store$")],
    },
    "VX_cache_top": {
        "xbar": [re.compile(
            r"^cache/g_cache_cache/(core_req_xbar|core_rsp_xbar|mem_req_xbar|mem_rsp_xbar)$"
        )],
        "sram": [
            re.compile(r"^cache/g_cache_cache/g_banks_\d+__bank/cache_data/g_data_store_\d+__data_store$"),
            re.compile(r"^cache/g_cache_cache/g_banks_\d+__bank/cache_tags/g_tag_store_\d+__tag_store$"),
            re.compile(r"^cache/g_cache_cache/g_banks_\d+__bank/cache_mshr/mshr_store$"),
        ],
    },
    "VX_axi_adapter": {
        "xbar": [re.compile(r"^(req_xbar|rsp_xbar)$")],
        "sram": [],
    },
}

LABEL_N = {
    "L1": 8, "L2": 16, "L3": 32, "L4": 64,
    "C0": 2, "C1": 4, "C2":  8, "C3": 16, "C4": 32,
    "A0": 2, "A1": 4, "A2":  8, "A3": 16, "A4": 32,
}


def _grab(rx, text):
    m = rx.search(text)
    return float(m.group(1)) if m else 0.0


def parse_total(text: str) -> float:
    return _grab(RE_TOTAL, text)


def parse_routing(rpt_area: Path, rpt_cong: Path):
    text = rpt_area.read_text(errors="ignore")
    out = {
        "cell_area":   _grab(RE_TOTAL, text),
        "macro_area":  _grab(RE_MACRO_AREA, text),
        "core_area":   _grab(RE_CORE, text),
        "util":        _grab(RE_UTIL, text),
        "overflow":      0.0,
        "overflow_pct":  0.0,
        "wirelength":    0.0,
    }
    if rpt_cong.exists():
        ctext = rpt_cong.read_text(errors="ignore")
        # The congestion report runs Zroute in 3 phases and reports a
        # final "Both Dirs: Overflow = ..." summary after phase3. Take the
        # LAST occurrence to capture the post-optimization residual.
        ms = list(RE_OVF.finditer(ctext))
        if ms:
            out["overflow"]     = float(ms[-1].group(1))
            out["overflow_pct"] = float(ms[-1].group(2))
        wls = list(RE_WL.finditer(ctext))
        if wls:
            out["wirelength"] = float(wls[-1].group(1))
    return out


def parse_hier(text: str):
    out = []
    for line in text.splitlines():
        m = RE_HIER_LINE.match(line)
        if m:
            out.append((m.group(1), float(m.group(2))))
    return out


def match_any(patterns, path: str) -> bool:
    return any(p.match(path) for p in patterns)


def extract_mem_point(top: str, label: str, rpt: Path):
    text = rpt.read_text(errors="ignore")
    total = parse_total(text)
    pats = PATTERNS[top]
    xbar_sum = 0.0
    sram_sum = 0.0
    for path, area in parse_hier(text):
        if match_any(pats["xbar"], path):
            xbar_sum += area
        elif match_any(pats["sram"], path):
            sram_sum += area
    ctrl = total - xbar_sum - sram_sum
    n = LABEL_N.get(label, 0)
    return [
        (top, label, n, "total", total),
        (top, label, n, "xbar",  xbar_sum),
        (top, label, n, "sram",  sram_sum),
        (top, label, n, "ctrl",  ctrl),
    ]


def collect_mem_subsys():
    rows, routing = [], []
    for top_dir in sorted(MEM_RUN.glob("VX_*")):
        top = top_dir.name
        if top not in PATTERNS:
            continue
        for label_dir in sorted(top_dir.glob("*")):
            label = label_dir.name
            rpt_dir = label_dir / "syn_topo.lpp" / "reports"
            rpt_area = rpt_dir / f"14_{top}.mapped.area.rpt"
            rpt_cong = rpt_dir / f"20_{top}.mapped.congestion.rpt"
            if not rpt_area.exists():
                print(f"[skip] {top}/{label}: no area report")
                continue
            rows.extend(extract_mem_point(top, label, rpt_area))
            r = parse_routing(rpt_area, rpt_cong)
            r.update({"design": top, "label": label, "n": LABEL_N.get(label, 0)})
            routing.append(r)
            print(f"[ok]   {top}/{label}: total={rows[-4][4]:>12.1f} util={r['util']:.3f} "
                  f"ovf={r['overflow']:>6.0f} ({r['overflow_pct']:.2f}%)")
    return rows, routing


def collect_gemm_unit():
    rpt_area = GEMM_RUN / "reports" / "14_VX_gemm_unit_top.mapped.area.rpt"
    rpt_cong = GEMM_RUN / "reports" / "20_VX_gemm_unit_top.mapped.congestion.rpt"
    if not rpt_area.exists():
        print(f"[warn] gemm-unit area report missing: {rpt_area}")
        return [], []
    text = rpt_area.read_text(errors="ignore")
    total = parse_total(text)
    r = parse_routing(rpt_area, rpt_cong)
    r.update({"design": "VX_gemm_unit_top", "label": "WKQ", "n": 0})
    print(f"[ok]   VX_gemm_unit_top/WKQ: total={total:>12.1f} util={r['util']:.3f}")
    return [("VX_gemm_unit_top", "WKQ", 0, "total", total)], [r]


def main():
    rows, routing = [], []
    m_rows, m_rout = collect_mem_subsys()
    g_rows, g_rout = collect_gemm_unit()
    rows.extend(m_rows); rows.extend(g_rows)
    routing.extend(m_rout); routing.extend(g_rout)

    out = HERE / "area.csv"
    with out.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["design", "label", "n", "kind", "area_um2"])
        for r in rows:
            w.writerow([r[0], r[1], r[2], r[3], f"{r[4]:.4f}"])
    print(f"\nwrote {len(rows)} rows -> {out}")

    out_r = HERE / "routing.csv"
    with out_r.open("w", newline="") as f:
        cols = ["design", "label", "n", "core_area", "util",
                "macro_area", "cell_area", "overflow", "overflow_pct", "wirelength"]
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in routing:
            w.writerow({k: (f"{r[k]:.4f}" if isinstance(r[k], float) else r[k]) for k in cols})
    print(f"wrote {len(routing)} rows -> {out_r}")


if __name__ == "__main__":
    main()
