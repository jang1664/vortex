"""Generate figures from scalar, TCU, and GEMM synthesis data.

Outputs (PNG + PDF):
  fig1_per_component_power.{png,pdf}
      Bar chart of power per single-instance FP module at p=10ns, FP16 vs FP32.
  fig2_native_vs_naive_mpgemm.{png,pdf}
      Native VX_gemm_unit (FP16xINT4) vs a naive baseline that dequantizes
      to FP16 first and runs FP16xFP16 GEMM. Power normalized per dot product.
  fig3_area_breakdown.{png,pdf}
      Stacked area for VX_gemm_unit (combinational/sequential/buf-inv).
  table_efficiency.csv
      TOPS/W and TOPS/mm^2 for FP TCU (synth) vs WoQ FPxINT (synth) vs
      WKV FPxINT (synth). Used as a paper table.
  fig10_wkv_vs_woq_relative_breakdown.{svg,png}
      Fig. 9 datapath groups normalized to WKV=1, with WoQ/WKV labels.
"""

from __future__ import annotations

import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = Path(__file__).resolve().parent
BASE_CSV = HERE / "data_base.csv"
TCU_CSV = HERE / "data_tcu.csv"
GEMM_CSV = HERE / "data_fpint_mxu.csv"

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

ONE_COL_WIDTH = 3.5
TWO_COL_WIDTH = 7.16
FULL_HEIGHT = 9.3


def display_name(name: str) -> str:
    """Paper-facing label: drop RTL instance prefix and underscores."""
    if name.startswith("u_"):
        name = name[2:]
    return name.replace("_", " ")


def load_csv(path: Path) -> list[dict]:
    rows = []
    with path.open() as f:
        for r in csv.DictReader(f):
            for k, v in list(r.items()):
                if k.endswith(("_uw", "_um2", "_ns")) or k == "period_ns":
                    try:
                        r[k] = float(v)
                    except ValueError:
                        r[k] = 0.0
            rows.append(r)
    return rows


def load() -> list[dict]:
    """Load static scalar/INT data and extracted TCU/GEMM data."""
    rows = load_csv(BASE_CSV) + load_csv(TCU_CSV) + load_csv(GEMM_CSV)
    keys = [(row["design"], row["precision"]) for row in rows]
    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    if duplicates:
        duplicate_text = ", ".join(
            f"{design}/{precision}" for design, precision in duplicates
        )
        raise ValueError(f"duplicate rows across input CSVs: {duplicate_text}")

    required = {
        ("fp_mult", "FP16"),
        ("fp_addsub", "FP32"),
        ("fp_i2flt", "FP16"),
        ("fp_flt2i", "FP16"),
        ("int_mac_pe", "INT8/INT32"),
        ("VX_tcu_unit_th32_bhf", "FP16/FP32acc"),
        ("VX_gemm_unit_32x32_mpGEMM", "FP16act/INT4w->FP32acc"),
        (
            "VX_woq_gemm_unit_32x32_mpGEMM",
            "FP16act/INT4w(W-only)->FP32acc",
        ),
    }
    missing = sorted(required - set(keys))
    if missing:
        missing_text = ", ".join(
            f"{design}/{precision}" for design, precision in missing
        )
        raise ValueError(f"required input rows are missing: {missing_text}")
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
    """VX_gemm_unit_top (WKV-quant) vs VX_woq_gemm_unit_top (W-only quant).

    Both are 32x32 mpGEMM at 100 MHz, FP16 act x INT4 weight, fully unrolled
    (1024 MAC/cycle = 204.8 GFLOP/s). VX additionally supports K/V quant
    (scale + zero-point per row/col); WoQ supports only weight quant.
    """
    vx = get(rows, "VX_gemm_unit_32x32_mpGEMM", "FP16act/INT4w->FP32acc")
    woq = get(
        rows,
        "VX_woq_gemm_unit_32x32_mpGEMM",
        "FP16act/INT4w(W-only)->FP32acc",
    )
    if not vx or not woq:
        return

    fig, axes = plt.subplots(1, 2, figsize=(11, 5.2))
    cats = ["VX (WKV-quant)", "VX (W-only quant)"]
    colors = [BLUE, GREEN]

    # Power
    pw = [vx["total_uw"] / 1000, woq["total_uw"] / 1000]  # mW
    bars = axes[0].bar(cats, pw, color=colors)
    for b, v in zip(bars, pw):
        axes[0].text(b.get_x() + b.get_width() / 2, v, f"{v:.1f} mW",
                     ha="center", va="bottom")
    axes[0].set_ylabel("Power (mW)")
    axes[0].set_title(f"Power — W-only is {pw[0]/pw[1]:.2f}x lower")
    axes[0].yaxis.grid(True, alpha=0.3)
    axes[0].set_axisbelow(True)

    # Area
    ar = [vx["area_um2"] / 1e6, woq["area_um2"] / 1e6]  # mm^2
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
    tops_woq = flops_s / woq["total_uw"] / 1e6
    dens_vx = (flops_s / 1e12) / (vx["area_um2"] / 1e6)
    dens_woq = (flops_s / 1e12) / (woq["area_um2"] / 1e6)
    print(f"[fig6] WKV vs W-only:")
    print(f"  VX (WKV)   : {pw[0]:.2f} mW, {ar[0]:.3f} mm^2, "
          f"{tops_vx:.2f} TOPS/W, {dens_vx:.3f} TOPS/mm^2")
    print(f"  VX (W-only): {pw[1]:.2f} mW, {ar[1]:.3f} mm^2, "
          f"{tops_woq:.2f} TOPS/W, {dens_woq:.3f} TOPS/mm^2")


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
        "u_mxu":                    "#08306b",
        "u_pre_proc_pipe_buffer":   "#08519c",
        "u_out_scaler_vec":         "#2171b5",
        "u_int2fp_vec":             "#4292c6",
        "u_accumulator_vec":        "#6baed6",
        "u_act_reduce":             "#9ecae1",
        "u_in_scaler_vec":          "#2f3b46",
        "u_zp_mul_out_reg":         "#4b5563",
        "u_act_reduce_shl_vec":     "#6b7280",
        "u_merger_vec":             "#9ca3af",
        "u_f32_to_f16_vec":         "#c7cdd4",
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


def fig8_wkv_vs_woq_breakdown():
    """Module-level power and WKV-over-WoQ power overhead per block."""
    bd_path = HERE / "wkvwoq_breakdown.csv"
    if not bd_path.exists():
        return
    insts, wkv_p, woq_p = [], [], []
    with bd_path.open() as f:
        r = csv.DictReader(f)
        for row in r:
            insts.append(row["instance"])
            wkv_p.append(float(row["WKV_uW"]) / 1000.0)
            woq_p.append(float(row["WoQ_uW"]) / 1000.0)

    colors = {
        "u_mxu":                    "#08306b",
        "u_pre_proc_pipe_buffer":   "#08519c",
        "u_out_scaler_vec":         "#2171b5",
        "u_int2fp_vec":             "#4292c6",
        "u_accumulator_vec":        "#6baed6",
        "u_act_reduce":             "#9ecae1",
        "u_in_scaler_vec":          "#2f3b46",
        "u_zp_mul_out_reg":         "#4b5563",
        "u_act_reduce_shl_vec":     "#6b7280",
        "u_merger_vec":             "#9ca3af",
        "u_f32_to_f16_vec":         "#c7cdd4",
    }

    fig, axes = plt.subplots(
        1, 2, figsize=(12.5, 6.4),
        gridspec_kw={"width_ratios": [0.95, 1.05]},
    )
    cats = ["WKV", "WoQ"]

    bottoms = [0.0, 0.0]
    handles = []
    for inst, wkv_v, woq_v in zip(insts, wkv_p, woq_p):
        vals = [wkv_v, woq_v]
        c = colors.get(inst, GRAY)
        bars = axes[0].bar(cats, vals, bottom=bottoms, color=c,
                           label=display_name(inst), edgecolor="white", linewidth=0.6)
        handles.append(bars[0])
        bottoms = [b + v for b, v in zip(bottoms, vals)]

    axes[0].set_ylabel("Power (mW)")
    axes[0].set_title("Module-level power")
    axes[0].yaxis.grid(True, alpha=0.3)
    axes[0].set_axisbelow(True)
    ymax = max(bottoms) * 1.16
    axes[0].set_ylim(0, ymax)
    for i, total in enumerate(bottoms):
        axes[0].text(i, total + ymax * 0.015, f"{total:.2f} mW",
                     ha="center", va="bottom", fontsize=13)

    overhead = [
        (inst, (wkv_v - woq_v))
        for inst, wkv_v, woq_v in zip(insts, wkv_p, woq_p)
        if (wkv_v - woq_v) > 0.001
    ]
    overhead.sort(key=lambda item: item[1])
    y = np.arange(len(overhead))
    overhead_vals = [v for _, v in overhead]
    overhead_colors = [colors.get(inst, GRAY) for inst, _ in overhead]
    axes[1].barh(y, overhead_vals, color=overhead_colors,
                 edgecolor="black", linewidth=0.4)
    axes[1].set_yticks(y)
    axes[1].set_yticklabels([display_name(inst) for inst, _ in overhead], fontsize=11)
    axes[1].set_xlabel("Δ Power, WKV − WoQ (mW)")
    total_overhead = sum(overhead_vals)
    axes[1].set_title(f"WKV overhead per block — total {total_overhead:.2f} mW")
    axes[1].xaxis.grid(True, alpha=0.3)
    axes[1].set_axisbelow(True)
    xmax = max(overhead_vals) * 1.24 if overhead_vals else 1.0
    axes[1].set_xlim(0, xmax)
    for yi, v in zip(y, overhead_vals):
        axes[1].text(v + xmax * 0.015, yi, f"{v:.3f}",
                     va="center", ha="left", fontsize=11)

    fig.suptitle(
        "32×32 mpGEMM @ 100 MHz, FP16 act × INT4 weight (VX gemm unit top)",
        y=0.99,
    )
    fig.legend(handles, [display_name(inst) for inst in insts],
               loc="lower center", bbox_to_anchor=(0.5, -0.01),
               ncol=4, fontsize=10.5, framealpha=0.95)
    fig.tight_layout(rect=[0, 0.18, 1, 0.93])
    out = HERE / "fig8_wkv_vs_woq_breakdown.svg"
    fig.savefig(out, dpi=300, bbox_inches="tight")
    plt.close(fig)
    print(f"[fig8] wrote {out}; WKV overhead = {total_overhead:.3f} mW")


WKV_WOQ_GROUPS = [
    ("MXU", {
        "u_mxu",
    }, "#17365d"),
    ("Preprocess", {
        "u_pre_proc_pipe_buffer",
        "u_prealigner",
        "u_prealign_blk_idx_pipe",
        "u_prealign_max_exp_pipe",
        "u_in_pipe",
        "u_act_reduce",
        "u_zp_mul_out_reg",
        "u_act_reduce_shl_vec",
    }, "#4c78a8"),
    ("Postprocess", {
        "u_out_scaler_vec",
        "u_int2fp_vec",
        "u_accumulator_vec",
        "u_acc_rd_fifo",
        "u_merger_vec",
        "u_merge_out_reg",
        "u_scaler_bypass_pipe",
        "u_f32_to_f16_vec",
        *{
            f"gen_mxu_output_dly_{i}__u_mxu_output_dly_pipe"
            for i in range(32)
        },
    }, "#b7c9e2"),
    ("Misc", {
        "u_misc",
    }, "#8c8c8c"),
    ("Input scaler", {
        "u_in_scaler_vec",
    }, "#2ca25f"),
]


def load_grouped_wkv_woq_breakdown(figure_name):
    """Load and aggregate module rows into the paper-facing datapath groups."""
    bd_path = HERE / "wkvwoq_breakdown.csv"
    if not bd_path.exists():
        return None
    insts, wkv_p, woq_p, wkv_a, woq_a = [], [], [], [], []
    with bd_path.open() as f:
        r = csv.DictReader(f)
        for row in r:
            insts.append(row["instance"])
            wkv_p.append(float(row["WKV_uW"]) / 1000.0)
            woq_p.append(float(row["WoQ_uW"]) / 1000.0)
            wkv_a.append(float(row["WKV_area_um2"]) / 1e6)
            woq_a.append(float(row["WoQ_area_um2"]) / 1e6)

    assigned = [inst for _, members, _ in WKV_WOQ_GROUPS for inst in members]
    duplicate_insts = sorted({inst for inst in assigned if assigned.count(inst) > 1})
    if duplicate_insts:
        raise ValueError(
            f"{figure_name} breakdown assigns modules to multiple groups: "
            + ", ".join(duplicate_insts)
        )
    unknown_insts = sorted(set(insts) - set(assigned))
    missing_insts = sorted(set(assigned) - set(insts))
    if unknown_insts or missing_insts:
        details = []
        if unknown_insts:
            details.append("unassigned modules: " + ", ".join(unknown_insts))
        if missing_insts:
            details.append("missing modules: " + ", ".join(missing_insts))
        raise ValueError(
            f"{figure_name} breakdown grouping mismatch; " + "; ".join(details)
        )

    index_by_inst = {inst: i for i, inst in enumerate(insts)}

    def aggregate(values):
        return [
            sum(values[index_by_inst[inst]] for inst in members)
            for _, members, _ in WKV_WOQ_GROUPS
        ]

    return {
        "labels": [label for label, _, _ in WKV_WOQ_GROUPS],
        "colors": [color for _, _, color in WKV_WOQ_GROUPS],
        "wkv_power": aggregate(wkv_p),
        "woq_power": aggregate(woq_p),
        "wkv_area": aggregate(wkv_a),
        "woq_area": aggregate(woq_a),
    }


def fig9_wkv_vs_woq_breakdown():
    """Combined power/area breakdown with paper-facing datapath groups."""
    breakdown = load_grouped_wkv_woq_breakdown("fig9")
    if breakdown is None:
        return
    labels = breakdown["labels"]
    colors = breakdown["colors"]
    grouped_wkv_p = breakdown["wkv_power"]
    grouped_woq_p = breakdown["woq_power"]
    grouped_wkv_a = breakdown["wkv_area"]
    grouped_woq_a = breakdown["woq_area"]

    with plt.rc_context({
        "font.size": 4.5,
        "axes.titlesize": 4.5,
        "axes.labelsize": 4.5,
        "xtick.labelsize": 4.5,
        "ytick.labelsize": 4.5,
        "legend.fontsize": 4.5,
    }):
        fig, axes = plt.subplots(
            2, 1, figsize=(ONE_COL_WIDTH, 1.8),
            gridspec_kw={"hspace": 1.20},
        )
        cats = ["WKV", "WoQ"]
        show_value_labels = False

        def draw_stacked_h(ax, left_vals, right_vals, title, total_fmt):
            bottoms = [0.0, 0.0]
            local_handles = []
            for label, color, left_v, right_v in zip(
                    labels, colors, left_vals, right_vals):
                vals = [left_v, right_v]
                bars = ax.barh(cats, vals, left=bottoms, height=0.42,
                               color=color, label=label, edgecolor="white",
                               linewidth=0.45)
                local_handles.append(bars[0])
                bottoms = [b + v for b, v in zip(bottoms, vals)]
            ax.set_title(title, fontsize=4.5)
            ax.xaxis.grid(True, alpha=0.3)
            ax.set_axisbelow(True)
            xmax = max(bottoms) * (1.14 if show_value_labels else 1.02)
            ax.set_xlim(0, xmax)
            if show_value_labels:
                for i, total in enumerate(bottoms):
                    ax.text(total + xmax * 0.012, i, total_fmt.format(total),
                            ha="left", va="center")
            return local_handles, bottoms

        handles, power_totals = draw_stacked_h(
            axes[0], grouped_wkv_p, grouped_woq_p,
            "power(mW)", "{:.2f} mW",
        )
        _, area_totals = draw_stacked_h(
            axes[1], grouped_wkv_a, grouped_woq_a,
            "area(mm2)", "{:.3f} mm²",
        )

        fig.legend(handles, labels,
                   loc="lower center", bbox_to_anchor=(0.5, -0.02),
                   ncol=5, columnspacing=0.8, handlelength=1.2,
                   handletextpad=0.4, framealpha=0.95)
        fig.subplots_adjust(left=0.08, right=0.93, top=0.94, bottom=0.23,
                            hspace=1.25)
        outputs = []
        for ext in ("svg", "png"):
            out = HERE / f"fig9_wkv_vs_woq_breakdown.{ext}"
            fig.savefig(out, dpi=300, bbox_inches="tight")
            outputs.append(out)
        plt.close(fig)
    print(f"[fig9] wrote {', '.join(str(out) for out in outputs)}; "
          f"power totals WKV={power_totals[0]:.2f} mW WoQ={power_totals[1]:.2f} mW, "
          f"area totals WKV={area_totals[0]:.3f} mm^2 WoQ={area_totals[1]:.3f} mm^2")


def fig10_wkv_vs_woq_relative_breakdown():
    """Fig. 9 breakdown normalized to WKV, without an x-axis scale."""
    breakdown = load_grouped_wkv_woq_breakdown("fig10")
    if breakdown is None:
        return

    labels = breakdown["labels"]
    colors = breakdown["colors"]

    def normalize_to_wkv(wkv_values, woq_values):
        wkv_total = sum(wkv_values)
        if wkv_total <= 0:
            raise ValueError("fig10 cannot normalize a zero-valued WKV total")
        return (
            [value / wkv_total for value in wkv_values],
            [value / wkv_total for value in woq_values],
        )

    wkv_power, woq_power = normalize_to_wkv(
        breakdown["wkv_power"], breakdown["woq_power"]
    )
    wkv_area, woq_area = normalize_to_wkv(
        breakdown["wkv_area"], breakdown["woq_area"]
    )

    with plt.rc_context({
        "font.size": 4.5,
        "axes.titlesize": 4.5,
        "axes.labelsize": 4.5,
        "xtick.labelsize": 4.5,
        "ytick.labelsize": 4.5,
        "legend.fontsize": 4.5,
    }):
        fig, axes = plt.subplots(
            2, 1, figsize=(ONE_COL_WIDTH, 1.8),
            gridspec_kw={"hspace": 0.45},
        )
        cats = ["WKV", "WoQ"]

        def draw_relative_stacked_h(ax, wkv_values, woq_values, title):
            totals = [0.0, 0.0]
            local_handles = []
            for label, color, wkv_value, woq_value in zip(
                    labels, colors, wkv_values, woq_values):
                values = [wkv_value, woq_value]
                bars = ax.barh(
                    cats, values, left=totals, height=0.42,
                    color=color, label=label, edgecolor="white",
                    linewidth=0.45,
                )
                local_handles.append(bars[0])
                totals = [
                    total + value for total, value in zip(totals, values)
                ]

            xmax = max(totals) * 1.14
            ax.set_xlim(0, xmax)
            ax.set_title(title, fontsize=4.5)
            ax.set_xlabel("")
            ax.set_xticks([])
            ax.tick_params(axis="x", which="both", bottom=False, labelbottom=False)
            ax.text(
                totals[0] + xmax * 0.015, 0, f"{totals[0]:.1f}",
                ha="left", va="center", fontsize=4.5,
            )
            ax.text(
                totals[1] + xmax * 0.015, 1, f"{totals[1]:.2f}×",
                ha="left", va="center", fontsize=4.5,
            )
            return local_handles, totals

        handles, power_totals = draw_relative_stacked_h(
            axes[0], wkv_power, woq_power, "power"
        )
        _, area_totals = draw_relative_stacked_h(
            axes[1], wkv_area, woq_area, "area"
        )

        fig.legend(
            handles, labels,
            loc="lower center", bbox_to_anchor=(0.5, 0.02),
            ncol=5, columnspacing=0.8, handlelength=1.2,
            handletextpad=0.4, framealpha=0.95,
        )
        fig.subplots_adjust(
            left=0.08, right=0.93, top=0.94, bottom=0.23, hspace=0.45
        )
        outputs = []
        for ext in ("svg", "png"):
            out = HERE / f"fig10_wkv_vs_woq_relative_breakdown.{ext}"
            fig.savefig(out, dpi=300, bbox_inches="tight")
            outputs.append(out)
        plt.close(fig)

    print(
        f"[fig10] wrote {', '.join(str(out) for out in outputs)}; "
        f"WoQ/WKV power={power_totals[1]:.3f}, "
        f"area={area_totals[1]:.3f}"
    )


def table_efficiency(rows):
    """Write TOPS/W and TOPS/mm^2 for the FP TCU, WoQ, and WKV engines.

    - FP TCU: thread-32 BHF synthesis, 8*4*4*2 MAC/cycle at 100 MHz,
      with 2 operations per MAC = 0.0512 TOPS.
    - WoQ FPxINT: VX_woq_gemm_unit_top synthesized total (weight-only quant).
    - WKV FPxINT: VX_gemm_unit_top synthesized total (W+K+V quant).
      Both GEMM engines sustain 32*32 MAC/cycle at 100 MHz = 0.2048 TOPS.
    Relative TOPS/W and TOPS/mm^2 are normalized to the FP TCU = 1.0.
    """
    tcu = get(rows, "VX_tcu_unit_th32_bhf", "FP16/FP32acc")
    wkv = get(rows, "VX_gemm_unit_32x32_mpGEMM", "FP16act/INT4w->FP32acc")
    woq = get(
        rows,
        "VX_woq_gemm_unit_32x32_mpGEMM",
        "FP16act/INT4w(W-only)->FP32acc",
    )

    tcu_tops = 8 * 4 * 4 * 2 * 2 * 1e8 / 1e12  # 0.0512 TOPS
    gemm_tops = 32 * 32 * 2 * 1e8 / 1e12       # 0.2048 TOPS

    configs = [
        ("FP TCU (synth)",      tcu["total_uw"], tcu["area_um2"], tcu_tops),
        ("WoQ FPxINT (synth)",  woq["total_uw"], woq["area_um2"], gemm_tops),
        ("WKV FPxINT (synth)",  wkv["total_uw"], wkv["area_um2"], gemm_tops),
    ]
    metrics = [
        (tops / (p / 1e6), tops / (a / 1e6))
        for _, p, a, tops in configs
    ]
    base_w, base_mm = metrics[0]  # FP TCU normalization base

    out = HERE / "table_efficiency.csv"
    with out.open("w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["config", "power_mW", "area_mm2", "TOPS",
                    "TOPS_per_W", "TOPS_per_mm2",
                    "rel_TOPS_per_W", "rel_TOPS_per_mm2"])
        for (name, p_uw, a_um2, tops), (tw, tmm) in zip(configs, metrics):
            w.writerow([name, f"{p_uw/1000:.3f}", f"{a_um2/1e6:.4f}",
                        f"{tops:.4f}",
                        f"{tw:.3f}", f"{tmm:.4f}",
                        f"{tw/base_w:.3f}", f"{tmm/base_mm:.3f}"])
    print(f"[table] wrote {out}")
    print(f"  {'config':<28} {'P (mW)':>8} {'A (mm^2)':>9} "
          f"{'TOPS/W':>8} {'TOPS/mm^2':>10} {'rel.W':>7} {'rel.mm2':>8}")
    for (name, p_uw, a_um2, _), (tw, tmm) in zip(configs, metrics):
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
    fig8_wkv_vs_woq_breakdown()
    fig9_wkv_vs_woq_breakdown()
    fig10_wkv_vs_woq_relative_breakdown()
    table_efficiency(rows)
    print(f"saved figures to {HERE}")


if __name__ == "__main__":
    main()
