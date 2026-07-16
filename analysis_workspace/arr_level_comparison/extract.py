"""Extract power and area metrics from synthesis runs and emit a CSV.

Walks the component_database tree, reads each module's
  - <design>_report_power.report  (PrimePower hierarchical, columns =
      Switch / Internal / Leakage / Total. Dynamic in mW, leakage in uW.)
  - 14_<design>.mapped.area.rpt   (DC area report)

and produces `data.csv` plus a small printable summary. All powers in CSV
are normalized to **microwatts (uW)** and area to **um^2**.
"""

from __future__ import annotations

import argparse
import csv
import re
from dataclasses import dataclass, asdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1] / "third_party" / "component_database"
# VX_gemm_unit_top syn/sim/pwr artifacts now live under vortex/build/...
# (the source-side scripts at vortex/hw/syn/synopsys/gemm_unit_breakdown/scripts
# write here; mirrored from the original location in component_database.)
VORTEX_BUILD_GEMM = HERE.parents[1] / "build" / "hw" / "syn" / "synopsys" \
    / "gemm_unit_breakdown" / "syn" / "run" / "v0"

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
    family: str           # "fp", "int", "gemm"
    precision: str        # "FP16", "FP32", "INT8", "mpINT4", etc.
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


def collect_fp_module(design: str, family: str = "fp"):
    """Iterate over period10.0_precision* dirs for a given fp design."""
    base = ROOT / "fp_operation" / design
    if not base.is_dir():
        return
    for cfg in sorted(base.glob("period*_precision*_pipeline*")):
        # Filter: keep only period=10
        if not cfg.name.startswith("period10.0_"):
            continue
        m = re.search(r"precision(\w+?)(?:_|$)", cfg.name)
        if not m:
            continue
        prec = m.group(1)
        rpt = cfg / "pwr.run1" / "reports" / f"{design}_report_power.report"
        area = cfg / "syn_topo.run1" / "reports" / f"14_{design}.mapped.area.rpt"
        qor = cfg / "syn_topo.run1" / "reports" / f"{design}.qor_snapshot.rpt"
        timing = cfg / "syn_topo.run1" / "reports" / f"12_{design}.mapped.timing.rpt"
        pw = parse_power_report(rpt, design)
        if pw is None:
            continue
        sw_uW, int_uW, leak_uW, tot_uW = pw
        ar = parse_area_report(area) or {"total": 0, "comb": 0, "seq": 0, "buf": 0}
        wns, crit, per = parse_qor(qor, timing)
        yield Row(
            design=design,
            family=family,
            precision=prec,
            period_ns=10.0,
            sw_uw=sw_uW,
            int_uw=int_uW,
            leak_uw=leak_uW,
            total_uw=tot_uW,
            area_um2=ar["total"] or 0,
            comb_area_um2=ar["comb"] or 0,
            seq_area_um2=ar["seq"] or 0,
            buf_area_um2=ar["buf"] or 0,
            wns_ns=wns or 0.0,
            crit_ns=crit or 0.0,
            rpt_path=str(rpt),
        )


def collect_fp_examples(design: str):
    """fp_mult / fp_addsub / fp_mac / fp_div / fp_exp at p10 from examples/."""
    base = ROOT / "fp_operation" / "examples" / design
    if not base.is_dir():
        return
    for cfg in sorted(base.glob("p10_format*_stage*")):
        m = re.search(r"format(\w+?)_stage", cfg.name)
        if not m:
            continue
        prec = m.group(1)
        rpt = cfg / "pwr.run1" / "reports" / f"{design}_report_power.report"
        area = cfg / "syn_topo.run1" / "reports" / f"14_{design}.mapped.area.rpt"
        qor = cfg / "syn_topo.run1" / "reports" / f"{design}.qor_snapshot.rpt"
        timing = cfg / "syn_topo.run1" / "reports" / f"12_{design}.mapped.timing.rpt"
        pw = parse_power_report(rpt, design)
        if pw is None:
            continue
        sw_uW, int_uW, leak_uW, tot_uW = pw
        ar = parse_area_report(area) or {"total": 0, "comb": 0, "seq": 0, "buf": 0}
        wns, crit, per = parse_qor(qor, timing)
        yield Row(
            design=design,
            family="fp",
            precision=prec,
            period_ns=10.0,
            sw_uw=sw_uW,
            int_uw=int_uW,
            leak_uw=leak_uW,
            total_uw=tot_uW,
            area_um2=ar["total"] or 0,
            comb_area_um2=ar["comb"] or 0,
            seq_area_um2=ar["seq"] or 0,
            buf_area_um2=ar["buf"] or 0,
            wns_ns=wns or 0.0,
            crit_ns=crit or 0.0,
            rpt_path=str(rpt),
        )


def collect_int_mac_pe():
    base = ROOT / "int_operation" / "int_mac_pe"
    for cfg in sorted(base.glob("period10.0_precision*")):
        m = re.search(r"precision(\w+)_pipeline\d+_out_precision(\w+)", cfg.name)
        if not m:
            continue
        prec = f"{m.group(1)}/{m.group(2)}"
        rpt = cfg / "pwr.run1" / "reports" / "int_mac_pe_report_power.report"
        area = cfg / "syn_topo.run1" / "reports" / "14_int_mac_pe.mapped.area.rpt"
        qor = cfg / "syn_topo.run1" / "reports" / "int_mac_pe.qor_snapshot.rpt"
        timing = cfg / "syn_topo.run1" / "reports" / "12_int_mac_pe.mapped.timing.rpt"
        pw = parse_power_report(rpt, "int_mac_pe")
        if pw is None:
            continue
        sw_uW, int_uW, leak_uW, tot_uW = pw
        ar = parse_area_report(area) or {"total": 0, "comb": 0, "seq": 0, "buf": 0}
        wns, crit, per = parse_qor(qor, timing)
        yield Row(
            design="int_mac_pe",
            family="int",
            precision=prec,
            period_ns=10.0,
            sw_uw=sw_uW,
            int_uw=int_uW,
            leak_uw=leak_uW,
            total_uw=tot_uW,
            area_um2=ar["total"] or 0,
            comb_area_um2=ar["comb"] or 0,
            seq_area_um2=ar["seq"] or 0,
            buf_area_um2=ar["buf"] or 0,
            wns_ns=wns or 0.0,
            crit_ns=crit or 0.0,
            rpt_path=str(rpt),
        )


def collect_ws_mxu():
    base = ROOT / "int_operation" / "ws_mxu" / "syn" / "run" / "v0" / "syn_topo.run1"
    rpt = base / "reports" / "18_mxu.mapped.power.rpt"
    area = base / "reports" / "14_mxu.mapped.area.rpt"
    qor = base / "reports" / "mxu.qor_snapshot.rpt"
    timing = base / "reports" / "12_mxu.mapped.timing.rpt"
    pw = parse_power_report(rpt, "mxu")
    if pw is None:
        return
    sw_uW, int_uW, leak_uW, tot_uW = pw
    ar = parse_area_report(area) or {"total": 0, "comb": 0, "seq": 0, "buf": 0}
    wns, crit, per = parse_qor(qor, timing)
    yield Row(
        design="ws_mxu_4x4_INT4xINT4",
        family="int",
        precision="INT4/INT4->INT10",
        period_ns=10.0,
        sw_uw=sw_uW,
        int_uw=int_uW,
        leak_uw=leak_uW,
        total_uw=tot_uW,
        area_um2=ar["total"] or 0,
        comb_area_um2=ar["comb"] or 0,
        seq_area_um2=ar["seq"] or 0,
        buf_area_um2=ar["buf"] or 0,
        wns_ns=wns or 0.0,
        crit_ns=crit or 0.0,
        rpt_path=str(rpt),
    )


def collect_vx_gemm():
    # Now top is VX_gemm_unit_top (flat-port wrapper) and the canonical
    # power report is the FSDB-annotated PrimePower one under pwr.run1/.
    # Falls back to the DC report_power output if pwr.run1 hasn't run.
    base_v = VORTEX_BUILD_GEMM
    syn = base_v / "syn_topo.run1"
    pwr_rpt = base_v / "pwr.run1" / "reports" / "VX_gemm_unit_top_report_power.report"
    if pwr_rpt.exists():
        rpt = pwr_rpt
    else:
        rpt = syn / "reports" / "18_VX_gemm_unit_top.mapped.power.rpt"
    area = syn / "reports" / "14_VX_gemm_unit_top.mapped.area.rpt"
    qor = syn / "reports" / "VX_gemm_unit_top.qor_snapshot.rpt"
    timing = syn / "reports" / "12_VX_gemm_unit_top.mapped.timing.rpt"
    pw = parse_power_report(rpt, "VX_gemm_unit_top")
    if pw is None:
        return
    sw_uW, int_uW, leak_uW, tot_uW = pw
    ar = parse_area_report(area) or {"total": 0, "comb": 0, "seq": 0, "buf": 0}
    wns, crit, per = parse_qor(qor, timing)
    yield Row(
        design="VX_gemm_unit_32x32_mpGEMM",
        family="gemm",
        precision="FP16act/INT4w->FP32acc",
        period_ns=10.0,
        sw_uw=sw_uW,
        int_uw=int_uW,
        leak_uw=leak_uW,
        total_uw=tot_uW,
        area_um2=ar["total"] or 0,
        comb_area_um2=ar["comb"] or 0,
        seq_area_um2=ar["seq"] or 0,
        buf_area_um2=ar["buf"] or 0,
        wns_ns=wns or 0.0,
        crit_ns=crit or 0.0,
        rpt_path=str(rpt),
    )


def collect_fpint_m32_scaled():
    """W-only quant 32x32 mpGEMM scaled from m64.tr4.tc8 measurements.

    The fpint MXU at m64.tr4.tc8 is fully unrolled: 128 PE instances * 32 MAC/PE
    = 4096 MAC/cycle. PE count scales as N^2 with mxu_size, peripherals as N.
    Scaling rule for 64 -> 32:
      - mxu (PE array) area/power /= 4
      - peripherals (prealigner, act_sum, reformatter, int2fp_array,
        data_setup) area/power /= 2
    Source: /mnt/digital_nfs/.../fpint/hw/pre_fp16_int4_mul/implementation/
    """
    M64 = "/mnt/digital_nfs/jaeyong.jang/Project/research/fpint/hw/pre_fp16_int4_mul/implementation"

    def grab(mod_dir, name):
        area_rpt = Path(M64) / mod_dir / "syn_topo" / "reports" / f"14_{name}.mapped.area.rpt"
        pwr_rpt = Path(M64) / mod_dir / "pwr" / "reports" / f"{name}_report_power.report"
        area = parse_area_report(area_rpt) or {"total": 0}
        pw = parse_power_report(pwr_rpt, name)
        tot_uW = pw[3] if pw else 0.0
        return area["total"] or 0.0, tot_uW

    a_mxu, p_mxu = grab("mxu.m64.f100.tr4.tc8", "mxu")
    a_pre, p_pre = grab("prealigner.m64.f100", "prealigner")
    a_act, p_act = grab("act_sum.m64.f100.tr4", "act_sum")
    a_i2f, p_i2f = grab("int2fp_array.m64.f100.tc8", "int2fp_array")
    a_ds,  p_ds  = grab("data_setup.m64.f100.tr4", "data_setup")
    a_ref, p_ref = grab("reformatter.m64.f100.tc8", "reformatter")

    # 64 -> 32 scaling
    mxu_a   = a_mxu / 4
    mxu_p   = p_mxu / 4
    perif_a = (a_pre + a_act + a_i2f + a_ds + a_ref) / 2
    perif_p = (p_pre + p_act + p_i2f + p_ds + p_ref) / 2
    total_a = mxu_a + perif_a
    total_p = mxu_p + perif_p

    yield Row(
        design="fpint_m32_W_only_quant_scaled",
        family="gemm",
        precision="FP16act/INT4w(W-only)",
        period_ns=10.0,
        sw_uw=0.0, int_uw=0.0, leak_uw=0.0,
        total_uw=total_p,
        area_um2=total_a,
        comb_area_um2=0, seq_area_um2=0, buf_area_um2=0,
        wns_ns=0.0, crit_ns=0.0,
        rpt_path=f"{M64}/* (scaled m64->m32, tr4.tc8 fixed)",
    )


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
        name = m_inst.group(1)
        if name not in WKVWOQ_INSTANCES:
            continue
        m = inline_pwr_re.search(raw)
        if not m and i + 1 < len(lines):
            m = nextline_pwr_re.match(lines[i + 1])
        if m:
            tot_W = float(m.group(4))
            out.setdefault(name, tot_W * 1e6)  # W -> uW
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
        name = m.group(1)
        if name in wanted:
            out.setdefault(name, float(m.group(2)))
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


def collect_all():
    rows = []
    # fp_operation main runs (where we generated fresh p10 data)
    for d in ("fp_mac_pe", "fp_sum3", "fp_sum4", "fp_add", "fp_flt2i", "fp_i2flt"):
        rows.extend(collect_fp_module(d))
    # fp_operation pre-existing examples (also p10)
    for d in ("fp_mult", "fp_addsub", "fp_mac", "fp_div", "fp_exp"):
        rows.extend(collect_fp_examples(d))
    rows.extend(collect_int_mac_pe())
    rows.extend(collect_ws_mxu())
    rows.extend(collect_vx_gemm())
    rows.extend(collect_fpint_m32_scaled())
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--breakdown-only",
        action="store_true",
        help="rebuild only wkvwoq_breakdown.csv from GEMM synthesis reports",
    )
    args = parser.parse_args()

    if not args.breakdown_only:
        rows = collect_all()
        available = {(row.design, row.precision) for row in rows}
        required = {
            ("fp_mult", "FP16"),
            ("fp_addsub", "FP32"),
            ("fp_flt2i", "FP16"),
            ("int_mac_pe", "INT8/INT32"),
            ("VX_gemm_unit_32x32_mpGEMM", "FP16act/INT4w->FP32acc"),
        }
        missing = sorted(required - available)
        if missing:
            missing_text = ", ".join(f"{design}/{precision}" for design, precision in missing)
            raise RuntimeError(
                "component reports are incomplete; refusing to overwrite data.csv. "
                f"Missing: {missing_text}. Use --breakdown-only to extract the GEMM breakdown."
            )

        out = HERE / "data.csv"
        fields = list(asdict(rows[0]).keys())
        with out.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
            w.writeheader()
            for row in rows:
                w.writerow(asdict(row))
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
