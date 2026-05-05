"""Scale the 32x32 GEMM unit to N=64, 128 by simple proportional rules.

Scaling assumptions (informed, not re-synthesized):
  - u_mxu (compute array)        : power & area ~ N^2  (MXU_ROW * MXU_COL)
  - All other blocks + top glue  : power & area ~ N    (MXU_ROW or MXU_COL)
  - Throughput                   : N^2 * f_clk * 2 FLOP/MAC

Bases at N=32, 100 MHz, FP16 act / INT4 weight, FP32 acc:
  - WKV FPxINT (synth) : VX_gemm_unit_top         (full WKV quant)
  - WoQ FPxINT (synth) : VX_woq_gemm_unit_top     (weight-only quant)
  - FPxFP (analytic)   : N^2 * fp_mult[FP16] + N*(N-1) * fp_addsub[FP32]
                         + N * fp_flt2i[FP16]    (no quant; FP32 acc)

For each N the relative columns are normalized so FPxFP @ that N = 1.0.

Output:
  - table_efficiency_scaled.csv (paper table)
  - stdout: human-readable summary
"""
from __future__ import annotations

import csv
from pathlib import Path

HERE = Path(__file__).resolve().parent

BASE_N = 32
F_CLK_HZ = 1.0e8

# --- Synth bases @ 32x32 (mxu vs rest split) ----------------------------------
# Power: WKV/WoQ totals from synthesis (data.csv / pwr_woq.run1 report).
# u_mxu power: from wkvwoq_breakdown.csv (PrimePower hierarchical).
# Area : top-level total from area.rpt; u_mxu area from same area.rpt
#        ("gemm_unit/u_mxu" line in 14_*.mapped.area.rpt).
SYNTH = {
    "WKV FPxINT": {
        "mxu_p_uW":  52800.000, "rest_p_uW":  93200.000 - 52800.000,
        "mxu_a_um2": 470610.7316, "rest_a_um2": 868874.396836 - 470610.7316,
    },
    "WoQ FPxINT": {
        "mxu_p_uW":  51900.000, "rest_p_uW":  90800.000 - 51900.000,
        "mxu_a_um2": 466151.5105, "rest_a_um2": 830707.709958 - 466151.5105,
    },
}

# --- FPxFP analytic per-unit (from data.csv) ----------------------------------
# fp_mult FP16, fp_addsub FP32 (matches FP32 acc), fp_flt2i FP16 (output cast).
FPXFP_UNIT = {
    "fp_mult_FP16":   {"p_uW": 120.0,   "a_um2":  899.144987},
    "fp_addsub_FP32": {"p_uW": 154.0,   "a_um2": 1004.44498},
    "fp_flt2i_FP16":  {"p_uW":  24.6,   "a_um2":  205.568998},
}


def scale_synth(name: str, n: int) -> tuple[float, float]:
    b = SYNTH[name]
    s = n / BASE_N
    p_uW = b["mxu_p_uW"] * s * s + b["rest_p_uW"] * s
    a_um2 = b["mxu_a_um2"] * s * s + b["rest_a_um2"] * s
    return p_uW, a_um2


def fpxfp(n: int) -> tuple[float, float]:
    m = FPXFP_UNIT["fp_mult_FP16"]
    a = FPXFP_UNIT["fp_addsub_FP32"]
    c = FPXFP_UNIT["fp_flt2i_FP16"]
    n_mult = n * n
    n_add = n * (n - 1)   # 31 adders per length-N tree, N trees => N*(N-1)
    n_cast = n
    p_uW = n_mult * m["p_uW"] + n_add * a["p_uW"] + n_cast * c["p_uW"]
    a_um2 = n_mult * m["a_um2"] + n_add * a["a_um2"] + n_cast * c["a_um2"]
    return p_uW, a_um2


def metrics(p_uW: float, a_um2: float, n: int) -> tuple[float, float, float]:
    tops = n * n * 2 * F_CLK_HZ / 1e12
    return tops, tops / (p_uW / 1e6), tops / (a_um2 / 1e6)


def main():
    sizes = (32, 64, 128)
    rows: list[dict] = []
    for n in sizes:
        configs = [
            ("FPxFP",      *fpxfp(n)),
            ("WoQ FPxINT", *scale_synth("WoQ FPxINT", n)),
            ("WKV FPxINT", *scale_synth("WKV FPxINT", n)),
        ]
        ms = [metrics(p, a, n) for _, p, a in configs]
        base_w, base_mm = ms[0][1], ms[0][2]   # FPxFP @ this N is the baseline
        for (name, p, a), (tops, tw, tmm) in zip(configs, ms):
            rows.append({
                "N": n, "config": name,
                "power_mW": p / 1000.0, "area_mm2": a / 1e6,
                "TOPS": tops,
                "TOPS_per_W": tw, "TOPS_per_mm2": tmm,
                "rel_TOPS_per_W": tw / base_w,
                "rel_TOPS_per_mm2": tmm / base_mm,
            })

    out = HERE / "table_efficiency_scaled.csv"
    fields = list(rows[0].keys())
    with out.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(fields)
        for r in rows:
            w.writerow([
                r["N"], r["config"],
                f"{r['power_mW']:.3f}", f"{r['area_mm2']:.4f}",
                f"{r['TOPS']:.4f}",
                f"{r['TOPS_per_W']:.3f}", f"{r['TOPS_per_mm2']:.4f}",
                f"{r['rel_TOPS_per_W']:.3f}", f"{r['rel_TOPS_per_mm2']:.3f}",
            ])
    print(f"wrote {out}\n")

    print(f"{'N':>4}  {'config':<12} {'P (mW)':>9} {'A (mm^2)':>10} "
          f"{'TOPS':>7} {'TOPS/W':>9} {'TOPS/mm^2':>11} "
          f"{'rel.W':>7} {'rel.mm2':>8}")
    print("-" * 90)
    for r in rows:
        print(f"{r['N']:>4}  {r['config']:<12} {r['power_mW']:>9.2f} "
              f"{r['area_mm2']:>10.3f} {r['TOPS']:>7.3f} "
              f"{r['TOPS_per_W']:>9.3f} {r['TOPS_per_mm2']:>11.4f} "
              f"{r['rel_TOPS_per_W']:>7.2f} {r['rel_TOPS_per_mm2']:>8.2f}")
        if r["config"] == "WKV FPxINT" and r["N"] != sizes[-1]:
            print()


if __name__ == "__main__":
    main()
