"""Extract TCU and GEMM-unit power and area metrics from synthesis reports.

Scalar FP and INT-unit measurements are kept in ``data_base.csv`` and are not
regenerated here. This script reads the thread-32 FP TCU report and the WKV/WoQ
reports under ``build/hw/syn/synopsys`` and writes ``data_tcu.csv`` and
``data_fpint_mxu.csv``. All powers in the CSV are normalized to microwatts
(uW), and area is in um^2.
"""

from __future__ import annotations

import argparse
import csv
import re
from dataclasses import dataclass, asdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
VORTEX_ROOT = HERE.parents[1]
# VX_gemm_unit_top syn/sim/pwr artifacts now live under vortex/build/...
# (the source-side scripts at vortex/hw/syn/synopsys/gemm_unit_breakdown/scripts
# write here; mirrored from the original location in component_database.)
VORTEX_BUILD_GEMM = VORTEX_ROOT / "build" / "hw" / "syn" / "synopsys" \
    / "gemm_unit_breakdown" / "syn" / "run" / "v0"
TCU_REPORT_DIR = VORTEX_ROOT / "build" / "hw" / "syn" / "synopsys" / "tcu" \
    / "synthesis_th32" / "tcu_unit_bhf" / "syn_topo.lpp" / "reports"
# The original thread-32 run's power report is currently absent from
# TCU_REPORT_DIR. This top-analysis block is the same mapped VX_tcu_unit
# design: its total cell area exactly matches the original 547111.533916 um^2.
TCU_POWER_FALLBACK = VORTEX_ROOT / "build" / "hw" / "syn" / "synopsys" \
    / "top_analysis" / "Vortex_tcu_th32_c1_rev2_subdesign_partial" / "blocks" \
    / "blocks" / "VX_tcu_unit__d2e8e198f1ee" / "reports" \
    / "18_VX_tcu_unit__d2e8e198f1ee.mapped.power.rpt"

# PrimePower emits two distinct hierarchical-power formats:
#   (a) "Report : Averaged Power"  — no units header, all values in Watts,
#                                    columns: Int Switch Leak Total
#   (b) "Report : power -hier -verbose" — header line "Dynamic Power Units = 1mW",
#                                    "Leakage Power Units = 1uW",
#                                    columns: Switch Int Leak Total
# We detect which format by looking for the units header, then map columns
# appropriately and scale to a uniform uW.
PWR_LINE_RE = re.compile(
    r"^(?P<name>\S+)\s+"
    r"(?P<a>[\d.eE+\-]+)\s+"
    r"(?P<b>[\d.eE+\-]+)\s+"
    r"(?P<c>[\d.eE+\-]+)\s+"
    r"(?P<d>[\d.eE+\-]+)\s+"
    r"\d+\.\d+\s*$"
)
AREA_TOTAL_RE = re.compile(r"^\s*Total cell area:\s+([\d.]+)", re.MULTILINE)
AREA_COMB_RE = re.compile(r"^\s*Combinational area:\s+([\d.]+)", re.MULTILINE)
AREA_SEQ_RE = re.compile(r"^\s*Noncombinational area:\s+([\d.]+)", re.MULTILINE)
AREA_BUF_RE = re.compile(r"^\s*Buf/Inv area:\s+([\d.]+)", re.MULTILINE)
QOR_WNS_RE = re.compile(r"Setup WNS:\s+(-?[\d.]+)")
QOR_CRIT_RE = re.compile(r"Critical Path Length:\s+([\d.]+)")
QOR_PERIOD_RE = re.compile(r"Critical Path Clk Period:\s+([\d.]+)")
TIMING_SLACK_RE = re.compile(
    r"^\s*slack\s+\([^)]+\)\s+(-?(?:\d+(?:\.\d*)?|\.\d+))\s*$",
    re.MULTILINE,
)


@dataclass
class Row:
    design: str
    family: str           # "gemm"
    precision: str        # "FP16act/INT4w->FP32acc", etc.
    period_ns: float
    sw_uw: float          # switching power, uW
    int_uw: float         # internal power, uW
    leak_uw: float        # leakage power, uW
    total_uw: float       # total power, uW
    area_um2: float       # total cell area
    comb_area_um2: float
    seq_area_um2: float
    buf_area_um2: float
    wns_ns: float
    crit_ns: float
    rpt_path: str


def parse_power_report(path: Path, top_name: str) -> tuple[float, float, float, float] | None:
    """Return (sw_uW, int_uW, leak_uW, total_uW) for the top module — uniform uW."""
    if not path.exists() or path.stat().st_size == 0:
        return None
    text = path.read_text(errors="ignore")
    verbose_format = "Dynamic Power Units = 1mW" in text
    # In verbose: dynamic (Switch, Int, Total) in mW, leakage in uW.
    # In averaged: all values in Watts.
    for line in text.splitlines():
        line = line.rstrip()
        if not line.startswith(top_name):
            continue
        m = PWR_LINE_RE.match(line)
        if not m:
            continue
        if m["name"] != top_name:
            continue
        a, b, c, d = float(m["a"]), float(m["b"]), float(m["c"]), float(m["d"])
        if verbose_format:
            # Cols: Switch Int Leak Total. Dynamic*=mW, Leak=uW, Total=mW.
            sw_uW = a * 1000.0
            int_uW = b * 1000.0
            leak_uW = c
            tot_uW = d * 1000.0
        else:
            # Cols: Int Switch Leak Total. All values in Watts.
            int_uW = a * 1e6
            sw_uW = b * 1e6
            leak_uW = c * 1e6
            tot_uW = d * 1e6
        return (sw_uW, int_uW, leak_uW, tot_uW)
    return None


def parse_area_report(path: Path):
    if not path.exists():
        return None
    text = path.read_text(errors="ignore")
    def grab(rx):
        m = rx.search(text)
        return float(m.group(1)) if m else None
    return {
        "total": grab(AREA_TOTAL_RE),
        "comb": grab(AREA_COMB_RE),
        "seq": grab(AREA_SEQ_RE),
        "buf": grab(AREA_BUF_RE),
    }


def parse_qor(path: Path, timing_path: Path | None = None):
    if path.exists():
        text = path.read_text(errors="ignore")
        wns = QOR_WNS_RE.search(text)
        crit = QOR_CRIT_RE.search(text)
        per = QOR_PERIOD_RE.search(text)
        if wns:
            return (
                float(wns.group(1)),
                float(crit.group(1)) if crit else None,
                float(per.group(1)) if per else None,
            )

    if timing_path is not None and timing_path.exists():
        text = timing_path.read_text(errors="ignore")
        # report_timing lists max-delay paths from worst to best.
        slack = TIMING_SLACK_RE.search(text)
        if slack:
            return float(slack.group(1)), None, None

    return None, None, None


def report_design_name(path: Path) -> str | None:
    if not path.exists():
        return None
    match = re.search(r"^Design\s*:\s*(\S+)", path.read_text(errors="ignore"), re.MULTILINE)
    return match.group(1) if match else None


def collect_tcu() -> Row | None:
    """Collect the synthesized thread-32 BHF FP TCU baseline."""
    area_candidates = [
        TCU_REPORT_DIR / "14_VX_tcu_unit.mapped.area.rpt",
        TCU_REPORT_DIR / "15_VX_tcu_unit.mapped.designware_area.rpt",
    ]
    power_candidates = [
        TCU_REPORT_DIR / "18_VX_tcu_unit.mapped.power.rpt",
        TCU_POWER_FALLBACK,
    ]
    area_path = next((path for path in area_candidates if path.exists()), None)
    power_path = next((path for path in power_candidates if path.exists()), None)
    if area_path is None or power_path is None:
        return None

    top_name = report_design_name(power_path)
    if top_name is None:
        return None
    pw = parse_power_report(power_path, top_name)
    ar = parse_area_report(area_path)
    if pw is None or ar is None or ar["total"] is None:
        return None

    sw_uW, int_uW, leak_uW, tot_uW = pw
    qor = TCU_REPORT_DIR / "11_VX_tcu_unit.mapped.qor.rpt"
    wns, crit, per = parse_qor(qor)
    return Row(
        design="VX_tcu_unit_th32_bhf",
        family="tcu",
        precision="FP16/FP32acc",
        period_ns=10.0,
        sw_uw=sw_uW,
        int_uw=int_uW,
        leak_uw=leak_uW,
        total_uw=tot_uW,
        area_um2=ar["total"],
        comb_area_um2=ar["comb"] or 0,
        seq_area_um2=ar["seq"] or 0,
        buf_area_um2=ar["buf"] or 0,
        wns_ns=wns or 0.0,
        crit_ns=crit or 0.0,
        rpt_path=str(power_path),
    )


def write_rows(path: Path, rows: list[Row]) -> None:
    fields = list(asdict(rows[0]).keys())
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow(asdict(row))


def collect_gemm_unit(
    *,
    design: str,
    top_name: str,
    precision: str,
    syn_run: str,
    pwr_run: str,
) -> Row | None:
    """Collect one GEMM top from the gemm_unit_breakdown build tree."""
    syn = VORTEX_BUILD_GEMM / syn_run
    pwr_rpt = (
        VORTEX_BUILD_GEMM / pwr_run / "reports" / f"{top_name}_report_power.report"
    )
    if pwr_rpt.exists():
        rpt = pwr_rpt
    else:
        rpt = syn / "reports" / f"18_{top_name}.mapped.power.rpt"
    area = syn / "reports" / f"14_{top_name}.mapped.area.rpt"
    qor = syn / "reports" / f"{top_name}.qor_snapshot.rpt"
    timing = syn / "reports" / f"12_{top_name}.mapped.timing.rpt"
    pw = parse_power_report(rpt, top_name)
    if pw is None:
        return None
    ar = parse_area_report(area)
    if ar is None or ar["total"] is None:
        return None
    sw_uW, int_uW, leak_uW, tot_uW = pw
    wns, crit, per = parse_qor(qor, timing)
    return Row(
        design=design,
        family="gemm",
        precision=precision,
        period_ns=10.0,
        sw_uw=sw_uW,
        int_uw=int_uW,
        leak_uw=leak_uW,
        total_uw=tot_uW,
        area_um2=ar["total"],
        comb_area_um2=ar["comb"] or 0,
        seq_area_um2=ar["seq"] or 0,
        buf_area_um2=ar["buf"] or 0,
        wns_ns=wns or 0.0,
        crit_ns=crit or 0.0,
        rpt_path=str(rpt),
    )


def collect_fpint_mxu() -> list[Row]:
    """Collect WKV and WoQ GEMM rows from gemm_unit_breakdown reports."""
    configs = [
        {
            "design": "VX_gemm_unit_32x32_mpGEMM",
            "top_name": "VX_gemm_unit_top",
            "precision": "FP16act/INT4w->FP32acc",
            "syn_run": "syn_topo.run1",
            "pwr_run": "pwr.run1",
        },
        {
            "design": "VX_woq_gemm_unit_32x32_mpGEMM",
            "top_name": "VX_woq_gemm_unit_top",
            "precision": "FP16act/INT4w(W-only)->FP32acc",
            "syn_run": "syn_topo_woq.run1",
            "pwr_run": "pwr_woq.run1",
        },
    ]
    rows = []
    for config in configs:
        row = collect_gemm_unit(**config)
        if row is not None:
            rows.append(row)
    return rows


# Module instances we want to break out for the WKV vs WoQ comparison.
# Order is the visual stack order in fig7 (bottom -> top).
WKVWOQ_INSTANCES = [
    "u_mxu",
    "u_pre_proc_pipe_buffer",
    "u_prealigner",
    "u_prealign_blk_idx_pipe",
    "u_prealign_max_exp_pipe",
    "u_in_pipe",
    "u_out_scaler_vec",
    "u_int2fp_vec",
    "u_accumulator_vec",
    "u_acc_rd_fifo",
    "u_act_reduce",
    "u_in_scaler_vec",
    "u_zp_mul_out_reg",
    "u_act_reduce_shl_vec",
    "u_merger_vec",
    "u_merge_out_reg",
    "u_scaler_bypass_pipe",
    "u_f32_to_f16_vec",
    *[
        f"gen_mxu_output_dly_{i}__u_mxu_output_dly_pipe"
        for i in range(32)
    ],
]
WKVWOQ_OUTPUT_INSTANCES = WKVWOQ_INSTANCES + ["u_misc"]

# Generated accumulator read FIFOs use elaborated hierarchy names. Normalize
# both banks into the single paper-facing u_acc_rd_fifo breakdown row so their
# area and power are counted as Postprocess rather than falling into u_misc.
INSTANCE_ALIASES = {
    f"gen_acc_rd_fifo_{bank}__u_acc_rd_fifo": "u_acc_rd_fifo"
    for bank in range(2)
}


def parse_module_breakdown(rpt_path: Path):
    """Return dict instance_name -> total_uW for the listed WKVWOQ_INSTANCES.

    The PrimePower hierarchical Averaged Power report puts the instance line
    either inline (`u_inst (Module)  Int Switch Leak Total %`) or split with
    the values on the next line when the instance label is too long.
    """
    if not rpt_path.exists():
        return {}
    # 5-column "Int Switch Leak Total %" tail. The tail can be inline with
    # the instance label (`u_mxu (Module) <Int> <Switch> <Leak> <Total> <pct>`)
    # or on the line right below (when the instance label wraps).
    inline_pwr_re = re.compile(
        r"\)\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+\d+\.\d+\s*$"
    )
    nextline_pwr_re = re.compile(
        r"^\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+([\d.eE+\-]+)\s+\d+\.\d+\s*$"
    )
    out = {}
    text = rpt_path.read_text(errors="ignore")
    lines = text.splitlines()
    for i, raw in enumerate(lines):
        # Look for direct module instance lines selected above.
        m_inst = re.match(r"^\s*(\w+)\s*\(", raw)
        if not m_inst:
            continue
        name = INSTANCE_ALIASES.get(m_inst.group(1), m_inst.group(1))
        if name not in WKVWOQ_INSTANCES:
            continue
        m = inline_pwr_re.search(raw)
        if not m and i + 1 < len(lines):
            m = nextline_pwr_re.match(lines[i + 1])
        if m:
            tot_W = float(m.group(4))
            out[name] = out.get(name, 0.0) + tot_W * 1e6  # W -> uW
    return out


def parse_module_area_breakdown(rpt_path: Path):
    """Return dict instance_name -> global cell area in um^2."""
    if not rpt_path.exists():
        return {}
    out = {}
    wanted = set(WKVWOQ_INSTANCES)
    line_re = re.compile(r"^\s*gemm_unit/([^/\s]+)\s+([\d.]+)\s+")
    for raw in rpt_path.read_text(errors="ignore").splitlines():
        m = line_re.match(raw)
        if not m:
            continue
        name = INSTANCE_ALIASES.get(m.group(1), m.group(1))
        if name in wanted:
            out[name] = out.get(name, 0.0) + float(m.group(2))
    return out


def collect_wkv_woq_breakdown():
    base = VORTEX_BUILD_GEMM
    wkv_rpt = base / "pwr.run1" / "reports" / "VX_gemm_unit_top_report_power.report"
    woq_rpt = base / "pwr_woq.run1" / "reports" / "VX_woq_gemm_unit_top_report_power.report"
    wkv_area_rpt = base / "syn_topo.run1" / "reports" / "14_VX_gemm_unit_top.mapped.area.rpt"
    woq_area_rpt = base / "syn_topo_woq.run1" / "reports" / "14_VX_woq_gemm_unit_top.mapped.area.rpt"
    wkv_power_total = parse_power_report(wkv_rpt, "VX_gemm_unit_top")
    woq_power_total = parse_power_report(woq_rpt, "VX_woq_gemm_unit_top")
    wkv_area_total = parse_area_report(wkv_area_rpt)
    woq_area_total = parse_area_report(woq_area_rpt)
    breakdown = {
        "WKV_power": parse_module_breakdown(wkv_rpt),
        "WoQ_power": parse_module_breakdown(woq_rpt),
        "WKV_area": parse_module_area_breakdown(wkv_area_rpt),
        "WoQ_area": parse_module_area_breakdown(woq_area_rpt),
    }
    totals = {
        "WKV_power": wkv_power_total[3] if wkv_power_total else None,
        "WoQ_power": woq_power_total[3] if woq_power_total else None,
        "WKV_area": wkv_area_total["total"] if wkv_area_total else None,
        "WoQ_area": woq_area_total["total"] if woq_area_total else None,
    }
    for metric, total in totals.items():
        if total is None:
            continue
        residual = total - sum(breakdown[metric].values())
        if residual < -1e-3:
            raise ValueError(
                f"{metric} submodule sum exceeds top-level total by {-residual:.3f}"
            )
        breakdown[metric]["u_misc"] = max(residual, 0.0)
    return breakdown


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--breakdown-only",
        action="store_true",
        help="rebuild only wkvwoq_breakdown.csv from GEMM synthesis reports",
    )
    mode.add_argument(
        "--tcu-only",
        action="store_true",
        help="rebuild only data_tcu.csv from the thread-32 TCU synthesis reports",
    )
    args = parser.parse_args()

    if not args.breakdown_only:
        tcu = collect_tcu()
        if tcu is None:
            raise RuntimeError(
                "TCU reports are incomplete; refusing to overwrite data_tcu.csv"
            )
        tcu_out = HERE / "data_tcu.csv"
        write_rows(tcu_out, [tcu])
        print(f"wrote TCU baseline -> {tcu_out}")
        print(
            f"  power={tcu.total_uw / 1000.0:.3f} mW, "
            f"area={tcu.area_um2 / 1e6:.6f} mm^2"
        )
        if args.tcu_only:
            return

    if not args.breakdown_only:
        rows = collect_fpint_mxu()
        available = {(row.design, row.precision) for row in rows}
        required = {
            ("VX_gemm_unit_32x32_mpGEMM", "FP16act/INT4w->FP32acc"),
            (
                "VX_woq_gemm_unit_32x32_mpGEMM",
                "FP16act/INT4w(W-only)->FP32acc",
            ),
        }
        missing = sorted(required - available)
        if missing:
            missing_text = ", ".join(f"{design}/{precision}" for design, precision in missing)
            raise RuntimeError(
                "GEMM reports are incomplete; refusing to overwrite "
                f"data_fpint_mxu.csv. Missing: {missing_text}. "
                "Use --breakdown-only to extract only the module breakdown."
            )

        out = HERE / "data_fpint_mxu.csv"
        write_rows(out, rows)
        print(f"wrote {len(rows)} rows -> {out}")
        # also dump a quick table to stdout
        print(f"\n{'design':<30} {'prec':<25} {'P_total (uW)':>14} {'area (um^2)':>14} {'WNS':>6}")
        print("-" * 90)
        for row in rows:
            print(f"{row.design:<30} {row.precision:<25} {row.total_uw:>14.3f} {row.area_um2:>14.1f} {row.wns_ns:>6.2f}")

    # WKV vs WoQ module-level breakdown
    bd = collect_wkv_woq_breakdown()
    bd_path = HERE / "wkvwoq_breakdown.csv"
    with bd_path.open("w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["instance", "WKV_uW", "WoQ_uW", "delta_uW",
                    "WKV_area_um2", "WoQ_area_um2", "delta_area_um2"])
        for inst in WKVWOQ_OUTPUT_INSTANCES:
            wkv = bd["WKV_power"].get(inst, 0.0)
            woq = bd["WoQ_power"].get(inst, 0.0)
            wkv_area = bd["WKV_area"].get(inst, 0.0)
            woq_area = bd["WoQ_area"].get(inst, 0.0)
            w.writerow([inst, f"{wkv:.3f}", f"{woq:.3f}", f"{wkv - woq:.3f}",
                        f"{wkv_area:.3f}", f"{woq_area:.3f}", f"{wkv_area - woq_area:.3f}"])
    print(f"\nWKV/WoQ module-level breakdown -> {bd_path}")
    print(f"{'instance':<28} {'WKV (uW)':>12} {'WoQ (uW)':>12} {'Δ (uW)':>10} "
          f"{'WKV area':>12} {'WoQ area':>12} {'Δ area':>10}")
    print("-" * 110)
    sum_wkv = sum_woq = sum_wkv_area = sum_woq_area = 0.0
    for inst in WKVWOQ_OUTPUT_INSTANCES:
        wkv = bd["WKV_power"].get(inst, 0.0)
        woq = bd["WoQ_power"].get(inst, 0.0)
        wkv_area = bd["WKV_area"].get(inst, 0.0)
        woq_area = bd["WoQ_area"].get(inst, 0.0)
        sum_wkv += wkv
        sum_woq += woq
        sum_wkv_area += wkv_area
        sum_woq_area += woq_area
        print(f"{inst:<28} {wkv:>12.3f} {woq:>12.3f} {wkv - woq:>10.3f} "
              f"{wkv_area:>12.1f} {woq_area:>12.1f} {wkv_area - woq_area:>10.1f}")
    print("-" * 110)
    print(f"{'(sum of listed)':<28} {sum_wkv:>12.3f} {sum_woq:>12.3f} {sum_wkv - sum_woq:>10.3f} "
          f"{sum_wkv_area:>12.1f} {sum_woq_area:>12.1f} {sum_wkv_area - sum_woq_area:>10.1f}")


if __name__ == "__main__":
    main()
