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

BLUE_DARK = "#0f4c81"
BLUE = "#2f80b7"
BLUE_LIGHT = "#6baed6"
BLUE_PALE = "#9ecae1"
TEAL = "#147d8f"
TEAL_LIGHT = "#41b6c4"
GREEN_DARK = "#1b7837"
GREEN = "#2ca25f"
GREEN_LIGHT = "#74c476"
GREEN_PALE = "#a1d99b"
GRAY = "#7a7f85"
TEXT = "#202124"

plt.rcParams.update({
    "font.size": 14,
    "axes.titlesize": 16,
    "axes.labelsize": 15,
    "xtick.labelsize": 13,
    "ytick.labelsize": 13,
    "legend.fontsize": 12,
    "figure.titlesize": 17,
    "pdf.fonttype": 42,
    "ps.fonttype": 42,
    "svg.fonttype": "none",
})


def display_name(name: str) -> str:
    """Paper-facing label: drop RTL instance prefix and underscores."""
    if name.startswith("u_"):
        name = name[2:]
    return name.replace("_", " ")


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
    fig, ax = plt.subplots(figsize=(11, 5.2))
    b1 = ax.bar(x - width / 2, fp16, width, label="FP16", color=BLUE)
    b2 = ax.bar(x + width / 2, fp32, width, label="FP32", color=GREEN)
    # Add an INT8 reference for context
    int_v = get(rows, "int_mac_pe", "INT8/INT32")
    if int_v:
        ax.axhline(int_v["total_uw"], color=GRAY, linestyle="--", linewidth=1.2,
                   label=f"{display_name('int_mac_pe')} (INT8) = {int_v['total_uw']:.1f} µW")

    ax.set_xticks(x)
    ax.set_xticklabels([display_name(d) for d in designs], rotation=25, ha="right")
    ax.set_ylabel("Power (µW)")
    ax.set_title("Per-component power @ 10 ns clock (28 nm LPP, ss 0.9 V 125°C)")
    ax.legend(loc="upper left", framealpha=0.95)
    ax.yaxis.grid(True, alpha=0.3)
    ax.set_axisbelow(True)
    for b, v in zip(list(b1) + list(b2), fp16 + fp32):
        if v > 0:
            ax.text(b.get_x() + b.get_width() / 2, v, f"{v:.0f}",
                    ha="center", va="bottom", fontsize=11)
    fig.tight_layout()
    for ext in ("png", "pdf", "svg"):
        fig.savefig(HERE / f"fig1_per_component_power.{ext}", dpi=300)
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

    fig, ax = plt.subplots(figsize=(8.5, 5.2))
    cats = ["Native mpGEMM\n(VX gemm unit)", "Naive FP16×FP16\n+ dequant"]
    bottoms = [0.0, 0.0]
    parts = [
        ("Multipliers (1024×fp mult)",  [native, naive_mult], BLUE_DARK),
        ("Adder tree 32×(31 fp addsub)", [0.0, naive_tree], BLUE_LIGHT),
        ("Dequant INT4→FP16 (32×fp i2flt)", [0.0, naive_dequant], GREEN),
        ("Output cast (32×fp flt2i)",  [0.0, naive_cast], GREEN_LIGHT),
    ]
    for label, vals, color in parts:
        ax.bar(cats, vals, bottom=bottoms, color=color, label=label,
               edgecolor="white", linewidth=0.6)
        bottoms = [b + v for b, v in zip(bottoms, vals)]

    for i, total in enumerate([native, naive_total]):
        ax.text(i, total, f"{total / 1000:.1f} mW", ha="center", va="bottom", fontsize=13)

    ratio = naive_total / native
    ax.set_ylabel("Power (µW)")
    ax.set_title(f"32×32 GEMM @ 100 MHz: native mpGEMM vs naive FP16×FP16 + dequant\n"
                 f"naive / native = {ratio:.2f}×")
    ax.legend(loc="upper left", fontsize=11)
    ax.yaxis.grid(True, alpha=0.3)
    ax.set_axisbelow(True)
    fig.tight_layout()
    for ext in ("png", "pdf", "svg"):
        fig.savefig(HERE / f"fig2_native_vs_naive_mpgemm.{ext}", dpi=300)
    plt.close(fig)
    print(f"[fig2] native = {native:.0f} µW, naive = {naive_total:.0f} µW "
          f"(mult={naive_mult:.0f}, tree={naive_tree:.0f}, "
          f"dequant={naive_dequant:.0f}, cast={naive_cast:.0f}); ratio = {ratio:.2f}×")


def fig3_area_breakdown(rows):
    r = get(rows, "VX_gemm_unit_32x32_mpGEMM", "FP16act/INT4w->FP32acc")
    if not r:
        return
    parts = [
        ("Combinational", r["comb_area_um2"], BLUE),
        ("Sequential", r["seq_area_um2"], GREEN),
        ("Buf/Inv", r["buf_area_um2"], TEAL_LIGHT),
    ]
    fig, ax = plt.subplots(figsize=(6.8, 5.2))
    labels = [p[0] for p in parts]
    vals = [p[1] for p in parts]
    colors = [p[2] for p in parts]
    bottom = 0.0
    for label, v, c in parts:
        ax.bar(["VX gemm unit\n32×32 mpGEMM"], [v], bottom=bottom, color=c, label=label,
               edgecolor="white", linewidth=0.6)
        ax.text(0, bottom + v / 2, f"{label}\n{v / 1000:.1f} k µm²",
                ha="center", va="center", color="white", fontsize=12)
        bottom += v
    ax.set_ylabel("Cell area (µm²)")
    ax.set_title(f"VX gemm unit area breakdown — total {bottom / 1000:.1f} k µm²")
    fig.tight_layout()
    for ext in ("png", "pdf", "svg"):
        fig.savefig(HERE / f"fig3_area_breakdown.{ext}", dpi=300)
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

    fig, ax = plt.subplots(figsize=(6.8, 5.2))
    cats = ["Native mpGEMM", "Naive FP16+dequant"]
    vals = [tops_native, tops_naive]
    colors = [BLUE, GREEN]
    bars = ax.bar(cats, vals, color=colors)
    for b, v in zip(bars, vals):
        ax.text(b.get_x() + b.get_width() / 2, v, f"{v:.2f}", ha="center", va="bottom")
    ax.set_ylabel("TOPS/W (1 MAC = 2 FLOPs)")
    ax.set_title("Energy efficiency at 32×32 GEMM, 100 MHz")
    ax.yaxis.grid(True, alpha=0.3)
    ax.set_axisbelow(True)
    fig.tight_layout()
    for ext in ("png", "pdf", "svg"):
        fig.savefig(HERE / f"fig4_tops_per_w.{ext}", dpi=300)
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

    fig, ax = plt.subplots(figsize=(6.8, 5.2))
    cats = ["Native mpGEMM", "Naive FP16+dequant"]
    vals = [native_tpmm, naive_tpmm]
    colors = [BLUE, GREEN]
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
        fig.savefig(HERE / f"fig5_tops_per_mm2.{ext}", dpi=300)
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

    fig, axes = plt.subplots(1, 2, figsize=(11, 5.2))
    cats = ["VX (WKV-quant)", "fpint m32 (W-only)"]
    colors = [BLUE, GREEN]

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
        fig.savefig(HERE / f"fig6_wkv_vs_w_only.{ext}", dpi=300)
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
    """Module-level area/power breakdown of WKV vs WoQ.

    Same RTL base, WoQ removes:
      - in_scaler vec (per-row activation × scale)
      - QROW data path in act_reduce/zp_mul (widths shrink, mux removed)
      - MXU column-direction weight load (smaller weight regs)
    """
    bd_path = HERE / "wkvwoq_breakdown.csv"
    if not bd_path.exists():
        return
    insts, wkv_p, woq_p, wkv_a, woq_a = [], [], [], [], []
    with bd_path.open() as f:
        r = csv.DictReader(f)
        for row in r:
            insts.append(row["instance"])
            wkv_p.append(float(row["WKV_uW"]))
            woq_p.append(float(row["WoQ_uW"]))
            wkv_a.append(float(row.get("WKV_area_um2") or 0.0))
            woq_a.append(float(row.get("WoQ_area_um2") or 0.0))

    # Use blue/green shades only; display labels are sanitized below.
    colors = {
        "u_mxu":                    BLUE_DARK,
        "u_pre_proc_pipe_buffer":   BLUE,
        "u_out_scaler_vec":         BLUE_LIGHT,
        "u_int2fp_vec":             BLUE_PALE,
        "u_accumulator_vec":        TEAL,
        "u_act_reduce":             TEAL_LIGHT,
        "u_in_scaler_vec":          GREEN_DARK,
        "u_zp_mul_out_reg":         GREEN,
        "u_act_reduce_shl_vec":     GREEN_LIGHT,
        "u_merger_vec":             GREEN_PALE,
        "u_f32_to_f16_vec":         GRAY,
    }

    fig, axes = plt.subplots(1, 2, figsize=(14, 6.8))
    cats = ["WKV", "WoQ"]
    handles = []

    def draw_stacked(ax, left_vals, right_vals, ylabel, title, total_fmt):
        bottoms = [0.0, 0.0]
        local_handles = []
        for inst, left_v, right_v in zip(insts, left_vals, right_vals):
            vals = [left_v, right_v]
            c = colors.get(inst, GRAY)
            bars = ax.bar(cats, vals, bottom=bottoms, color=c,
                          label=display_name(inst), edgecolor="white", linewidth=0.6)
            local_handles.append(bars[0])
            bottoms = [b + v for b, v in zip(bottoms, vals)]
        ax.set_ylabel(ylabel)
        ax.set_title(title)
        ax.yaxis.grid(True, alpha=0.3)
        ax.set_axisbelow(True)
        ymax = max(bottoms) * 1.16
        ax.set_ylim(0, ymax)
        for i, total in enumerate(bottoms):
            ax.text(i, total + ymax * 0.015, total_fmt.format(total),
                    ha="center", va="bottom", fontsize=13)
        return local_handles, bottoms

    handles, area_totals = draw_stacked(
        axes[0],
        [v / 1e6 for v in wkv_a],
        [v / 1e6 for v in woq_a],
        "Area (mm²)",
        "Module-level area",
        "{:.3f} mm²",
    )
    _, power_totals = draw_stacked(
        axes[1],
        [v / 1000 for v in wkv_p],
        [v / 1000 for v in woq_p],
        "Power (mW)",
        "Module-level power",
        "{:.2f} mW",
    )

    fig.suptitle(
        "32×32 mpGEMM @ 100 MHz, FP16 act × INT4 weight (VX gemm unit top)",
        y=1.0
    )
    fig.legend(handles, [display_name(inst) for inst in insts],
               loc="lower center", bbox_to_anchor=(0.5, -0.01),
               ncol=4, fontsize=11, framealpha=0.95)
    fig.tight_layout(rect=[0, 0.22, 1, 0.94])
    for ext in ("png", "pdf", "svg"):
        fig.savefig(HERE / f"fig7_wkv_vs_woq_breakdown.{ext}", dpi=300,
                    bbox_inches="tight")
    plt.close(fig)
    print(f"[fig7] area: WKV={area_totals[0]:.3f} mm^2, WoQ={area_totals[1]:.3f} mm^2, "
          f"delta={area_totals[0] - area_totals[1]:.3f} mm^2")
    print(f"[fig7] power: WKV={power_totals[0]:.2f} mW, WoQ={power_totals[1]:.2f} mW, "
          f"delta={power_totals[0] - power_totals[1]:.2f} mW")


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
