"""Generate figures from data.csv.

Outputs (PNG + PDF):
  fig1_per_component_power.{png,pdf}
      Bar chart of power per single-instance FP module at p=10ns, FP16 vs FP32.
  fig2_native_vs_naive_mpgemm.{png,pdf}
      Native VX_gemm_unit (FP16xINT4) vs a naive baseline that dequantizes
      to FP16 first and runs FP16xFP16 GEMM. Power normalized per dot product.
  fig3_area_breakdown.{png,pdf}
      Stacked area for VX_gemm_unit (combinational/sequential/buf-inv).
  table_efficiency.csv
      TOPS/W and TOPS/mm^2 for FPxFP (analytic) vs WoQ FPxINT (synth) vs
      WKV FPxINT (synth). Used as a paper table.
"""

from __future__ import annotations

import csv
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = Path(__file__).resolve().parent
CSV = HERE / "data.csv"
VORTEX_BUILD_GEMM = HERE.parents[1] / "build" / "hw" / "syn" / "synopsys" \
    / "gemm_unit_breakdown" / "syn" / "run" / "v0"


def load() -> list[dict]:
    rows = []
    with CSV.open() as f:
        for r in csv.DictReader(f):
            for k, v in list(r.items()):
                if k.endswith(("_uw", "_um2", "_ns")) or k == "period_ns":
                    try:
                        r[k] = float(v)
                    except ValueError:
                        r[k] = 0.0
            rows.append(r)
    return rows


def get(rows, design, prec=None):
    for r in rows:
        if r["design"] == design and (prec is None or r["precision"] == prec):
            return r
    return None


def fig1_per_component(rows):
    designs = ["fp_mult", "fp_addsub", "fp_add", "fp_mac", "fp_mac_pe",
               "fp_sum3", "fp_sum4", "fp_flt2i", "fp_i2flt"]
    fp16 = [get(rows, d, "FP16")["total_uw"] if get(rows, d, "FP16") else 0 for d in designs]
    fp32 = [get(rows, d, "FP32")["total_uw"] if get(rows, d, "FP32") else 0 for d in designs]

    x = np.arange(len(designs))
    width = 0.38
    fig, ax = plt.subplots(figsize=(9, 4.2))
    b1 = ax.bar(x - width / 2, fp16, width, label="FP16", color="#3a7ca5")
    b2 = ax.bar(x + width / 2, fp32, width, label="FP32", color="#d9774a")
    # Add an INT8 reference for context
    int_v = get(rows, "int_mac_pe", "INT8/INT32")
    if int_v:
        ax.axhline(int_v["total_uw"], color="#444", linestyle="--", linewidth=1,
                   label=f"int_mac_pe (INT8) = {int_v['total_uw']:.1f} µW")

    ax.set_xticks(x)
    ax.set_xticklabels(designs, rotation=25, ha="right")
    ax.set_ylabel("Power (µW)")
    ax.set_title("Per-component power @ 10 ns clock (28 nm LPP, ss 0.9 V 125°C)")
    ax.legend(loc="upper left", framealpha=0.95)
    ax.yaxis.grid(True, alpha=0.3)
    ax.set_axisbelow(True)
    for b, v in zip(list(b1) + list(b2), fp16 + fp32):
        if v > 0:
            ax.text(b.get_x() + b.get_width() / 2, v, f"{v:.0f}",
                    ha="center", va="bottom", fontsize=7)
    fig.tight_layout()
    for ext in ("png", "pdf", "svg"):
        fig.savefig(HERE / f"fig1_per_component_power.{ext}", dpi=200)
    plt.close(fig)


def fig2_native_vs_naive(rows):
    """Compare VX_gemm_unit (32x32 mpGEMM) vs naive FP16xFP16 + dequant baseline.

    Naive baseline composition for a 32x32 GEMM (32 parallel dot products of
    length 32) using mult + adder-tree decomposition:
      - 1024 FP16 multipliers : 32 dot products × 32 mults each
      - 992 FP32 binary adders: 32 dot products × 31 adders each.
        For each 32-input dot product, a depth-5 binary reduction tree uses
        16+8+4+2+1 = 31 adders. Adder = fp_addsub at FP32 to match the
        native VX_gemm_unit FP32 accumulator (FP16act/INT4w->FP32acc).
      - Per-column dequant (INT4 weight -> FP16): 32 × fp_i2flt(FP16)
      - Output cast FP32->FP16: 32 × fp_flt2i(FP16)
    Native: VX_gemm_unit (32x32 mpGEMM) total power, as synthesized.
    """
    fp_mult = get(rows, "fp_mult", "FP16")["total_uw"]
    fp_addsub = get(rows, "fp_addsub", "FP32")["total_uw"]
    i2flt = get(rows, "fp_i2flt", "FP16")["total_uw"]
    flt2i = get(rows, "fp_flt2i", "FP16")["total_uw"]
    native = get(rows, "VX_gemm_unit_32x32_mpGEMM", "FP16act/INT4w->FP32acc")["total_uw"]

    naive_mult = 1024 * fp_mult
    naive_tree = 992 * fp_addsub
    naive_dequant = 32 * i2flt
    naive_cast = 32 * flt2i
    naive_total = naive_mult + naive_tree + naive_dequant + naive_cast

    fig, ax = plt.subplots(figsize=(7, 4.2))
    cats = ["Native mpGEMM\n(VX_gemm_unit)", "Naive FP16×FP16\n+ dequant"]
    bottoms = [0.0, 0.0]
    parts = [
        ("Multipliers (1024×fp_mult)",  [native, naive_mult],    "#3a7ca5"),
        ("Adder tree 32×(31 fp_addsub)", [0.0,   naive_tree],    "#5dade2"),
        ("Dequant INT4→FP16 (32×fp_i2flt)", [0.0, naive_dequant], "#d9774a"),
        ("Output cast (32×fp_flt2i)",  [0.0,    naive_cast],     "#9b59b6"),
    ]
    for label, vals, color in parts:
        ax.bar(cats, vals, bottom=bottoms, color=color, label=label,
               edgecolor="white", linewidth=0.6)
        bottoms = [b + v for b, v in zip(bottoms, vals)]

    for i, total in enumerate([native, naive_total]):
        ax.text(i, total, f"{total / 1000:.1f} mW", ha="center", va="bottom", fontsize=10)

    ratio = naive_total / native
    ax.set_ylabel("Power (µW)")
    ax.set_title(f"32×32 GEMM @ 100 MHz: native mpGEMM vs naive FP16×FP16 + dequant\n"
                 f"naive / native = {ratio:.2f}×")
    ax.legend(loc="upper left", fontsize=8)
    ax.yaxis.grid(True, alpha=0.3)
    ax.set_axisbelow(True)
    fig.tight_layout()
    for ext in ("png", "pdf", "svg"):
        fig.savefig(HERE / f"fig2_native_vs_naive_mpgemm.{ext}", dpi=200)
    plt.close(fig)
    print(f"[fig2] native = {native:.0f} µW, naive = {naive_total:.0f} µW "
          f"(mult={naive_mult:.0f}, tree={naive_tree:.0f}, "
          f"dequant={naive_dequant:.0f}, cast={naive_cast:.0f}); ratio = {ratio:.2f}×")


def fig3_area_breakdown(rows):
    r = get(rows, "VX_gemm_unit_32x32_mpGEMM", "FP16act/INT4w->FP32acc")
    if not r:
        return
    parts = [
        ("Combinational", r["comb_area_um2"], "#3a7ca5"),
        ("Sequential", r["seq_area_um2"], "#d9774a"),
        ("Buf/Inv", r["buf_area_um2"], "#9b59b6"),
    ]
    fig, ax = plt.subplots(figsize=(5.5, 4.2))
    labels = [p[0] for p in parts]
    vals = [p[1] for p in parts]
    colors = [p[2] for p in parts]
    bottom = 0.0
    for label, v, c in parts:
        ax.bar(["VX_gemm_unit\n32×32 mpGEMM"], [v], bottom=bottom, color=c, label=label,
               edgecolor="white", linewidth=0.6)
        ax.text(0, bottom + v / 2, f"{label}\n{v / 1000:.1f} k µm²",
                ha="center", va="center", color="white", fontsize=8)
        bottom += v
    ax.set_ylabel("Cell area (µm²)")
    ax.set_title(f"VX_gemm_unit area breakdown — total {bottom / 1000:.1f} k µm²")
    fig.tight_layout()
    for ext in ("png", "pdf", "svg"):
        fig.savefig(HERE / f"fig3_area_breakdown.{ext}", dpi=200)
    plt.close(fig)


def fig4_tops_per_w(rows):
    """TOPS/W comparison: VX_gemm_unit (mpGEMM) vs naive baseline at 32x32, 100 MHz.

    Baseline uses the mult+adder-tree decomposition matched to fig2.
    """
    native = get(rows, "VX_gemm_unit_32x32_mpGEMM", "FP16act/INT4w->FP32acc")["total_uw"]
    fp_mult = get(rows, "fp_mult", "FP16")["total_uw"]
    fp_addsub = get(rows, "fp_addsub", "FP32")["total_uw"]
    i2flt = get(rows, "fp_i2flt", "FP16")["total_uw"]
    flt2i = get(rows, "fp_flt2i", "FP16")["total_uw"]
    naive_total = 1024 * fp_mult + 992 * fp_addsub + 32 * i2flt + 32 * flt2i

    # Throughput: 32x32 = 1024 MAC/cycle * 100 MHz = 102.4 GMAC/s = 204.8 GFLOP/s
    flops_s = 32 * 32 * 2 * 1e8  # 2 FLOP per MAC (mul + add)
    tops_native = flops_s / native / 1e6  # uW -> W: /1e6, ops/s -> TOPS: /1e12
    tops_naive = flops_s / naive_total / 1e6
    # 1 TOPS/W = 1e12 ops/(W*s); flops/s / W = ops_per_W_per_s; /1e12 = TOPS/W

    fig, ax = plt.subplots(figsize=(5.5, 4.2))
    cats = ["Native mpGEMM", "Naive FP16+dequant"]
    vals = [tops_native, tops_naive]
    colors = ["#3a7ca5", "#d9774a"]
    bars = ax.bar(cats, vals, color=colors)
    for b, v in zip(bars, vals):
        ax.text(b.get_x() + b.get_width() / 2, v, f"{v:.2f}", ha="center", va="bottom")
    ax.set_ylabel("TOPS/W (1 MAC = 2 FLOPs)")
    ax.set_title("Energy efficiency at 32×32 GEMM, 100 MHz")
    ax.yaxis.grid(True, alpha=0.3)
    ax.set_axisbelow(True)
    fig.tight_layout()
    for ext in ("png", "pdf", "svg"):
        fig.savefig(HERE / f"fig4_tops_per_w.{ext}", dpi=200)
    plt.close(fig)
    print(f"[fig4] TOPS/W: native={tops_native:.2f}, naive={tops_naive:.2f}, "
          f"speedup={tops_native / tops_naive:.2f}×")


def fig5_tops_per_mm2(rows):
    """TOPS/mm^2 (compute density) for native VX_gemm_unit_top vs the naive
    mult+adder-tree+dequant compose baseline.

    Naive area = 1024*fp_mult + 992*fp_addsub + 32*fp_i2flt + 32*fp_flt2i,
    matching the power compose used in fig2.
    """
    native = get(rows, "VX_gemm_unit_32x32_mpGEMM", "FP16act/INT4w->FP32acc")
    fp_mult = get(rows, "fp_mult", "FP16")
    fp_addsub = get(rows, "fp_addsub", "FP32")
    i2flt = get(rows, "fp_i2flt", "FP16")
    flt2i = get(rows, "fp_flt2i", "FP16")

    naive_mult_area = 1024 * fp_mult["area_um2"]
    naive_tree_area = 992 * fp_addsub["area_um2"]
    naive_dequant_area = 32 * i2flt["area_um2"]
    naive_cast_area = 32 * flt2i["area_um2"]
    naive_area_um2 = naive_mult_area + naive_tree_area + naive_dequant_area + naive_cast_area

    # 32x32 = 1024 MAC/cycle * 100 MHz * 2 FLOP/MAC = 204.8 GFLOP/s = 0.2048 TOPS
    flops_s = 32 * 32 * 2 * 1e8
    tops = flops_s / 1e12

    native_area_mm2 = native["area_um2"] / 1e6
    naive_area_mm2 = naive_area_um2 / 1e6
    native_tpmm = tops / native_area_mm2
    naive_tpmm = tops / naive_area_mm2

    fig, ax = plt.subplots(figsize=(5.5, 4.2))
    cats = ["Native mpGEMM", "Naive FP16+dequant"]
    vals = [native_tpmm, naive_tpmm]
    colors = ["#3a7ca5", "#d9774a"]
    bars = ax.bar(cats, vals, color=colors)
    for b, v in zip(bars, vals):
        ax.text(b.get_x() + b.get_width() / 2, v, f"{v:.3f}",
                ha="center", va="bottom")
    ax.set_ylabel("TOPS/mm²  (1 MAC = 2 FLOPs)")
    ax.set_title(
        "Compute density at 32×32 GEMM, 100 MHz\n"
        f"native area = {native_area_mm2:.3f} mm², "
        f"naive area = {naive_area_mm2:.3f} mm² (compose)"
    )
    ax.yaxis.grid(True, alpha=0.3)
    ax.set_axisbelow(True)
    fig.tight_layout()
    for ext in ("png", "pdf", "svg"):
        fig.savefig(HERE / f"fig5_tops_per_mm2.{ext}", dpi=200)
    plt.close(fig)
    print(f"[fig5] TOPS/mm^2: native={native_tpmm:.3f} (area {native_area_mm2:.3f} mm^2), "
          f"naive={naive_tpmm:.3f} (area {naive_area_mm2:.3f} mm^2 = "
          f"mult {naive_mult_area/1e6:.3f}+tree {naive_tree_area/1e6:.3f}"
          f"+dequant {naive_dequant_area/1e6:.4f}+cast {naive_cast_area/1e6:.4f}), "
          f"density ratio = {native_tpmm / naive_tpmm:.2f}x")


def fig6_wkv_vs_w_only(rows):
    """VX_gemm_unit_top (WKV-quant) vs fpint m32.tr4.tc8 (W-only quant).

    Both are 32x32 mpGEMM at 100 MHz, FP16 act x INT4 weight, fully unrolled
    (1024 MAC/cycle = 204.8 GFLOP/s). VX additionally supports K/V quant
    (scale + zero-point per row/col); fpint supports only weight quant.
    """
    vx = get(rows, "VX_gemm_unit_32x32_mpGEMM", "FP16act/INT4w->FP32acc")
    fp = get(rows, "fpint_m32_W_only_quant_scaled", "FP16act/INT4w(W-only)")
    if not vx or not fp:
        return

    fig, axes = plt.subplots(1, 2, figsize=(9, 4.2))
    cats = ["VX (WKV-quant)", "fpint m32 (W-only)"]
    colors = ["#3a7ca5", "#d9774a"]

    # Power
    pw = [vx["total_uw"] / 1000, fp["total_uw"] / 1000]  # mW
    bars = axes[0].bar(cats, pw, color=colors)
    for b, v in zip(bars, pw):
        axes[0].text(b.get_x() + b.get_width() / 2, v, f"{v:.1f} mW",
                     ha="center", va="bottom")
    axes[0].set_ylabel("Power (mW)")
    axes[0].set_title(f"Power — W-only is {pw[0]/pw[1]:.2f}x lower")
    axes[0].yaxis.grid(True, alpha=0.3)
    axes[0].set_axisbelow(True)

    # Area
    ar = [vx["area_um2"] / 1e6, fp["area_um2"] / 1e6]  # mm^2
    bars = axes[1].bar(cats, ar, color=colors)
    for b, v in zip(bars, ar):
        axes[1].text(b.get_x() + b.get_width() / 2, v, f"{v:.3f} mm²",
                     ha="center", va="bottom")
    axes[1].set_ylabel("Area (mm²)")
    axes[1].set_title(f"Area — W-only is {ar[0]/ar[1]:.2f}x smaller")
    axes[1].yaxis.grid(True, alpha=0.3)
    axes[1].set_axisbelow(True)

    fig.suptitle("32×32 mpGEMM @ 100 MHz, FP16 act × INT4 weight (1024 MAC/cycle)",
                 y=1.0)
    fig.tight_layout()
    for ext in ("png", "pdf", "svg"):
        fig.savefig(HERE / f"fig6_wkv_vs_w_only.{ext}", dpi=200)
    plt.close(fig)
    flops_s = 32 * 32 * 2 * 1e8
    tops_vx = flops_s / vx["total_uw"] / 1e6
    tops_fp = flops_s / fp["total_uw"] / 1e6
    dens_vx = (flops_s / 1e12) / (vx["area_um2"] / 1e6)
    dens_fp = (flops_s / 1e12) / (fp["area_um2"] / 1e6)
    print(f"[fig6] WKV vs W-only:")
    print(f"  VX (WKV)   : {pw[0]:.2f} mW, {ar[0]:.3f} mm^2, "
          f"{tops_vx:.2f} TOPS/W, {dens_vx:.3f} TOPS/mm^2")
    print(f"  fpint(W-on): {pw[1]:.2f} mW, {ar[1]:.3f} mm^2, "
          f"{tops_fp:.2f} TOPS/W, {dens_fp:.3f} TOPS/mm^2")


def fig7_wkv_vs_woq_breakdown():
    """Module-level breakdown of WKV (VX_gemm_unit_top) vs WoQ
    (VX_woq_gemm_unit_top). Same RTL base, WoQ removes:
      - in_scaler vec (per-row activation × scale)
      - QROW data path in act_reduce/zp_mul (widths shrink, mux removed)
      - MXU column-direction weight load (smaller weight regs)
    """
    bd_path = HERE / "wkvwoq_breakdown.csv"
    if not bd_path.exists():
        return
    insts, wkv, woq = [], [], []
    with bd_path.open() as f:
        r = csv.DictReader(f)
        for row in r:
            insts.append(row["instance"])
            wkv.append(float(row["WKV_uW"]))
            woq.append(float(row["WoQ_uW"]))

    # Color map: WKV-only blocks highlighted differently
    colors = {
        "u_mxu":                    "#3a7ca5",
        "u_pre_proc_pipe_buffer":   "#5dade2",
        "u_out_scaler_vec":         "#9b59b6",
        "u_int2fp_vec":             "#8e44ad",
        "u_accumulator_vec":        "#16a085",
        "u_act_reduce":             "#e67e22",
        "u_in_scaler_vec":          "#c0392b",   # WKV-specific
        "u_zp_mul_out_reg":         "#d9774a",
        "u_act_reduce_shl_vec":     "#f39c12",
        "u_merger_vec":             "#7f8c8d",
        "u_f32_to_f16_vec":         "#34495e",
    }

    fig, axes = plt.subplots(1, 2, figsize=(11, 5.0))
    cats = ["WKV", "WoQ"]
    bottoms = [0.0, 0.0]
    for inst, wkv_v, woq_v in zip(insts, wkv, woq):
        vals = [wkv_v / 1000, woq_v / 1000]  # uW -> mW
        c = colors.get(inst, "#888")
        axes[0].bar(cats, vals, bottom=bottoms, color=c, label=inst,
                    edgecolor="white", linewidth=0.6)
        bottoms = [b + v for b, v in zip(bottoms, vals)]
    axes[0].set_ylabel("Power (mW)")
    axes[0].set_title("Module-level power")
    axes[0].yaxis.grid(True, alpha=0.3)
    axes[0].set_axisbelow(True)
    axes[0].legend(loc="center left", bbox_to_anchor=(1.0, 0.5), fontsize=8)
    for i, t in enumerate(bottoms):
        axes[0].text(i, t, f"{t:.2f} mW", ha="center", va="bottom", fontsize=10)

    # Right pane: per-block delta (WKV - WoQ). Drop near-zero deltas
    # (|Δ| < 1 µW = 0.001 mW) so only the contributing blocks remain.
    DELTA_EPS_MW = 0.001
    raw_deltas = [(wkv_v - woq_v) / 1000 for wkv_v, woq_v in zip(wkv, woq)]
    total_delta = sum(raw_deltas)
    keep = [i for i, d in enumerate(raw_deltas) if abs(d) >= DELTA_EPS_MW]
    order = sorted(keep, key=lambda i: -raw_deltas[i])
    labels = [insts[i] for i in order]
    vals = [raw_deltas[i] for i in order]
    bar_colors = [colors.get(insts[i], "#888") for i in order]
    axes[1].barh(labels[::-1], vals[::-1], color=bar_colors[::-1])
    axes[1].set_xlabel("Δ Power, WKV − WoQ  (mW)")
    axes[1].set_title(f"WKV overhead per block — total {total_delta:.2f} mW")
    axes[1].xaxis.grid(True, alpha=0.3)
    axes[1].set_axisbelow(True)
    for i, v in enumerate(vals[::-1]):
        axes[1].text(v, i, f"  {v:+.3f}", va="center", fontsize=8)

    fig.suptitle(
        "32×32 mpGEMM @ 100 MHz, FP16 act × INT4 weight (VX_gemm_unit_top)",
        y=1.0
    )
    fig.tight_layout()
    for ext in ("png", "pdf", "svg"):
        fig.savefig(HERE / f"fig7_wkv_vs_woq_breakdown.{ext}", dpi=200,
                    bbox_inches="tight")
    plt.close(fig)
    total_wkv = sum(wkv) / 1000
    total_woq = sum(woq) / 1000
    print(f"[fig7] WKV={total_wkv:.2f} mW, WoQ={total_woq:.2f} mW, "
          f"WKV overhead={total_wkv - total_woq:.2f} mW "
          f"({100 * (total_wkv - total_woq) / total_wkv:.1f}%)")


def _parse_woq_totals():
    """Parse WoQ top-level power (W -> uW) and area (um^2) from synthesis."""
    pwr_rpt = VORTEX_BUILD_GEMM / "pwr_woq.run1" / "reports" \
        / "VX_woq_gemm_unit_top_report_power.report"
    area_rpt = VORTEX_BUILD_GEMM / "syn_topo_woq.run1" / "reports" \
        / "14_VX_woq_gemm_unit_top.mapped.area.rpt"
    total_uw = None
    if pwr_rpt.exists():
        # Averaged Power format: cols Int Switch Leak Total in Watts.
        line_re = re.compile(
            r"^VX_woq_gemm_unit_top\s+"
            r"([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+"
            r"\d+\.\d+\s*$"
        )
        for line in pwr_rpt.read_text(errors="ignore").splitlines():
            m = line_re.match(line)
            if m:
                total_uw = float(m.group(4)) * 1e6  # W -> uW
                break
    area_um2 = None
    if area_rpt.exists():
        m = re.search(r"^\s*Total cell area:\s+([\d.]+)",
                      area_rpt.read_text(errors="ignore"), re.MULTILINE)
        if m:
            area_um2 = float(m.group(1))
    return total_uw, area_um2


def table_efficiency(rows):
    """Write TOPS/W and TOPS/mm^2 table for FPxFP vs WoQ FPxINT vs WKV FPxINT.

    32x32 GEMM @ 100 MHz, 1024 MAC/cycle * 2 FLOP/MAC = 0.2048 TOPS.
    - FPxFP: analytic compose using component_database
      (1024*fp_mult[FP16] + 992*fp_addsub[FP32] + 32*fp_flt2i[FP16]).
      Same compose as fig2's naive baseline minus the INT4->FP16 dequant.
      Adder tree is FP32 to match the native VX_gemm_unit FP32 accumulator.
    - WoQ FPxINT: VX_woq_gemm_unit_top synthesized total (weight-only quant).
    - WKV FPxINT: VX_gemm_unit_top synthesized total (W+K+V quant).
    Relative TOPS/W and TOPS/mm^2 are normalized to FPxFP = 1.0.
    """
    fp_mult = get(rows, "fp_mult", "FP16")
    fp_addsub = get(rows, "fp_addsub", "FP32")
    flt2i = get(rows, "fp_flt2i", "FP16")
    wkv = get(rows, "VX_gemm_unit_32x32_mpGEMM", "FP16act/INT4w->FP32acc")

    fpxfp_p = (1024 * fp_mult["total_uw"]
               + 992 * fp_addsub["total_uw"]
               + 32 * flt2i["total_uw"])
    fpxfp_a = (1024 * fp_mult["area_um2"]
               + 992 * fp_addsub["area_um2"]
               + 32 * flt2i["area_um2"])

    woq_p, woq_a = _parse_woq_totals()
    if woq_p is None or woq_a is None:
        print("[table] WoQ synthesis reports missing — skipping CSV")
        return

    tops = 32 * 32 * 2 * 1e8 / 1e12  # 0.2048 TOPS

    configs = [
        ("FPxFP (analytic compose)", fpxfp_p, fpxfp_a),
        ("WoQ FPxINT (synth)",       woq_p,   woq_a),
        ("WKV FPxINT (synth)",       wkv["total_uw"], wkv["area_um2"]),
    ]
    metrics = [(tops / (p / 1e6), tops / (a / 1e6)) for _, p, a in configs]
    base_w, base_mm = metrics[0]  # FPxFP normalization base

    out = HERE / "table_efficiency.csv"
    with out.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["config", "power_mW", "area_mm2", "TOPS",
                    "TOPS_per_W", "TOPS_per_mm2",
                    "rel_TOPS_per_W", "rel_TOPS_per_mm2"])
        for (name, p_uw, a_um2), (tw, tmm) in zip(configs, metrics):
            w.writerow([name, f"{p_uw/1000:.3f}", f"{a_um2/1e6:.4f}",
                        f"{tops:.4f}",
                        f"{tw:.3f}", f"{tmm:.4f}",
                        f"{tw/base_w:.3f}", f"{tmm/base_mm:.3f}"])
    print(f"[table] wrote {out}")
    print(f"  {'config':<28} {'P (mW)':>8} {'A (mm^2)':>9} "
          f"{'TOPS/W':>8} {'TOPS/mm^2':>10} {'rel.W':>7} {'rel.mm2':>8}")
    for (name, p_uw, a_um2), (tw, tmm) in zip(configs, metrics):
        print(f"  {name:<28} {p_uw/1000:8.2f} {a_um2/1e6:9.3f} "
              f"{tw:8.3f} {tmm:10.4f} {tw/base_w:7.2f} {tmm/base_mm:8.2f}")


def main():
    rows = load()
    fig1_per_component(rows)
    fig2_native_vs_naive(rows)
    fig3_area_breakdown(rows)
    fig4_tops_per_w(rows)
    fig5_tops_per_mm2(rows)
    fig6_wkv_vs_w_only(rows)
    fig7_wkv_vs_woq_breakdown()
    table_efficiency(rows)
    print(f"saved figures to {HERE}")


if __name__ == "__main__":
    main()
