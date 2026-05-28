"""Synthesize VX_barrel_shifter over WIDTH and collect area/power/delay.

Default sweep:
    WIDTH = 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096
    period = 10 ns (100 MHz)

Run from a Python with hwexplorer installed:
    conda activate stable
    PYTHONPATH=/home/jaeyong.jang/project.local/research/hwexplorer \
      python analysis_workspace/barrel_shifter_sweep/sweep.py

Outputs:
    analysis_workspace/barrel_shifter_sweep/results.csv
    analysis_workspace/barrel_shifter_sweep/results.png
    build/hw/syn/synopsys/barrel_shifter_sweep/w<WIDTH>/syn_topo.lpp/
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from dataclasses import dataclass
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
VORTEX = HERE.parents[1]
HWEXPLORER = VORTEX.parent / "hwexplorer"
if HWEXPLORER.exists():
    sys.path.insert(0, str(HWEXPLORER))

from hwexplorer.automation.syn import SynthConfig  # noqa: E402
from hwexplorer.automation.tcl_directives import Corner  # noqa: E402
from hwexplorer.report_parser import (  # noqa: E402
    SynopsysDesignCompilerAreaParser,
    SynopsysDesignCompilerPowerParser,
    SynopsysDesignCompilerTimingParser,
)

RTL = VORTEX / "hw/rtl/patch/VX_barrel_shifter.sv"
BUILD_ROOT = VORTEX / "build/hw/syn/synopsys/barrel_shifter_sweep"
DESIGN = "VX_barrel_shifter"
DEFAULT_WIDTHS = [8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096]
DEFAULT_PERIOD_NS = 10.0


@dataclass(frozen=True)
class Point:
    width: int
    period_ns: float

    @property
    def design_dir(self) -> Path:
        return BUILD_ROOT / f"w{self.width}"

    @property
    def syn_dir_name(self) -> str:
        return "syn_topo.lpp"

    @property
    def run_dir(self) -> Path:
        return self.design_dir / self.syn_dir_name


def parse_widths(raw: str) -> list[int]:
    widths = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        width = int(item, 0)
        if width <= 1:
            raise ValueError("WIDTH must be > 1 because shift_amount uses $clog2(WIDTH)")
        widths.append(width)
    if not widths:
        raise ValueError("no WIDTH values supplied")
    return widths


def synthesize(point: Point) -> None:
    cfg = SynthConfig(
        design_dir=str(point.design_dir),
        syn_dir=point.syn_dir_name,
        design_name=DESIGN,
        search_path=[str(RTL.parent)],
        define_list=["SYNTHESIS"],
        an_source_list=[str(RTL)],
        param_list=[("WIDTH", point.width)],
        period=point.period_ns,
        period_scale=1.0,
        clk_nonideal_scale=0.0,
        input_delay_max=0.0,
        input_delay_min=0.0,
        output_delay_max=0.0,
        output_delay_min=0.0,
        clk_name="clk",
        reset_name="",
        reset_type="active_high",
        switching_activity={
            # DC power is vectorless here; these keep input activity explicit
            # and consistent across WIDTH points.
            "in*": [0.5, 0.02],
            "shift_amount*": [0.5, 0.02],
            "valid": [0.5, 0.02],
        },
        tech="lpp",
        corners=[Corner.MAX],
        driving_cells=[],
        driven_loads=[],
        rerun=True,
        backup=False,
        new=True,
    )
    print(f"[synth] WIDTH={point.width}, period={point.period_ns:g} ns")
    cfg.run()


def reports_complete(point: Point) -> bool:
    reports = point.run_dir / "reports"
    return all(
        (reports / name).exists()
        for name in (
            f"14_{DESIGN}.mapped.area.rpt",
            f"12_{DESIGN}.mapped.timing.rpt",
            f"18_{DESIGN}.mapped.power.rpt",
        )
    )


def _first_float(value, default=None):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def parse_area(area_rpt: Path) -> dict[str, float | int | None]:
    out = {
        "total_cell_area_um2": None,
        "comb_area_um2": None,
        "seq_area_um2": None,
        "buf_inv_area_um2": None,
        "core_area_um2": None,
        "utilization": None,
        "num_cells": None,
        "num_seq_cells": None,
    }
    if not area_rpt.exists():
        return out
    db = SynopsysDesignCompilerAreaParser().load(str(area_rpt))
    m = db.metadata
    out.update({
        "total_cell_area_um2": _first_float(m.get("total_cell_area")),
        "comb_area_um2": _first_float(m.get("combinational_area")),
        "seq_area_um2": _first_float(m.get("noncombinational_area")),
        "buf_inv_area_um2": _first_float(m.get("buf_inv_area")),
        "core_area_um2": _first_float(m.get("core_area")),
        "utilization": _first_float(m.get("utilization_ratio")),
        "num_cells": int(float(m.get("num_cells", 0) or 0)),
        "num_seq_cells": int(float(m.get("num_sequential_cells", 0) or 0)),
    })
    return out


def parse_power(power_rpt: Path) -> dict[str, float | None]:
    out = {
        "switch_power_mw": None,
        "internal_power_mw": None,
        "leakage_power_uw": None,
        "leakage_power_mw": None,
        "total_power_mw": None,
    }
    if not power_rpt.exists():
        return out
    db = SynopsysDesignCompilerPowerParser().load(str(power_rpt))
    if db.HIERARCHY_KEY not in db.tables or db.tables[db.HIERARCHY_KEY].empty:
        return out
    df = db.tables[db.HIERARCHY_KEY]
    top_rows = df[df["depth"] == 0]
    row = top_rows.iloc[0] if len(top_rows) else df.iloc[0]
    leakage_uw = _first_float(row.get("leak_power"))
    out.update({
        "switch_power_mw": _first_float(row.get("switch_power")),
        "internal_power_mw": _first_float(row.get("internal_power")),
        "leakage_power_uw": leakage_uw,
        "leakage_power_mw": None if leakage_uw is None else leakage_uw / 1000.0,
        "total_power_mw": _first_float(row.get("power")),
    })
    return out


def parse_timing(timing_rpt: Path, period_ns: float) -> dict[str, float | str | None]:
    out = {
        "delay_ns": None,
        "min_slack_ns": None,
        "wns_ns": None,
        "fmax_est_mhz": None,
        "critical_startpoint": None,
        "critical_endpoint": None,
        "critical_path_group": None,
    }
    if not timing_rpt.exists():
        return out
    db = SynopsysDesignCompilerTimingParser().load(str(timing_rpt))
    if db.PATHS_KEY not in db.tables or db.tables[db.PATHS_KEY].empty:
        return out
    df = db.tables[db.PATHS_KEY]
    idx = df["data_arrival_time"].astype(float).idxmax()
    row = df.loc[idx]
    delay = float(row["data_arrival_time"])
    min_slack = float(df["slack"].astype(float).min())
    out.update({
        "delay_ns": delay,
        "min_slack_ns": min_slack,
        "wns_ns": min(0.0, min_slack),
        "fmax_est_mhz": 1000.0 / max(1e-12, period_ns - min_slack),
        "critical_startpoint": row.get("startpoint"),
        "critical_endpoint": row.get("endpoint"),
        "critical_path_group": row.get("path_group"),
    })
    return out


def parse_errors(run_dir: Path) -> str:
    log_dir = run_dir / "logs"
    if not log_dir.exists():
        return ""
    ignored = (
        "Cannot find the specified driving cell in memory",
        "Can't find lib_pin",
        "Value for list '<library_cell_pin>' must have 1 elements",
    )
    messages: list[str] = []
    for path in sorted(log_dir.glob("run.log.*"))[-2:]:
        text = path.read_text(errors="ignore")
        hits = re.findall(r"^(?:Error|Fatal):.*$", text, flags=re.MULTILINE)
        messages.extend(hit for hit in hits if not any(s in hit for s in ignored))
    return " | ".join(messages[:10])


def parse_point(point: Point) -> dict:
    reports = point.run_dir / "reports"
    area_rpt = reports / f"14_{DESIGN}.mapped.area.rpt"
    timing_rpt = reports / f"12_{DESIGN}.mapped.timing.rpt"
    power_rpt = reports / f"18_{DESIGN}.mapped.power.rpt"
    row = {
        "width": point.width,
        "period_ns": point.period_ns,
        "run_dir": str(point.run_dir.relative_to(VORTEX)),
        "status": "ok" if area_rpt.exists() and timing_rpt.exists() and power_rpt.exists() else "missing_reports",
    }
    row.update(parse_area(area_rpt))
    row.update(parse_timing(timing_rpt, point.period_ns))
    row.update(parse_power(power_rpt))
    err = parse_errors(point.run_dir)
    row["errors"] = err
    return row


def write_csv(rows: list[dict], path: Path) -> None:
    cols = [
        "width", "period_ns", "status",
        "total_cell_area_um2", "comb_area_um2", "seq_area_um2",
        "buf_inv_area_um2", "core_area_um2", "utilization",
        "num_cells", "num_seq_cells",
        "delay_ns", "min_slack_ns", "wns_ns", "fmax_est_mhz",
        "switch_power_mw", "internal_power_mw",
        "leakage_power_uw", "leakage_power_mw", "total_power_mw",
        "critical_startpoint", "critical_endpoint", "critical_path_group",
        "run_dir", "errors",
    ]
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=cols)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def plot(rows: list[dict], path: Path) -> None:
    ok = [r for r in rows if r["status"] == "ok"]
    if not ok:
        return
    widths = [r["width"] for r in ok]
    area_mm2 = [r["total_cell_area_um2"] / 1e6 for r in ok]
    power_mw = [r["total_power_mw"] for r in ok]
    delay_ns = [r["delay_ns"] for r in ok]

    fig, axes = plt.subplots(1, 3, figsize=(13.5, 3.8))
    series = [
        (axes[0], area_mm2, "Area", "Total cell area (mm²)", "#3a5c75"),
        (axes[1], power_mw, "Power", "Total power (mW)", "#d9774a"),
        (axes[2], delay_ns, "Delay", "Critical data arrival (ns)", "#5a8a3b"),
    ]
    for ax, ys, title, ylabel, color in series:
        ax.plot(widths, ys, marker="o", linewidth=1.8, color=color)
        for x, y in zip(widths, ys):
            ax.text(x, y, f"{y:.4g}", ha="center", va="bottom", fontsize=8)
        ax.set_xscale("log", base=2)
        ax.set_xticks(widths)
        ax.set_xticklabels([str(w) for w in widths])
        ax.set_xlabel("WIDTH")
        ax.set_ylabel(ylabel)
        ax.set_title(title)
        ax.grid(True, which="both", alpha=0.3)
        ax.set_axisbelow(True)
    fig.suptitle("VX_barrel_shifter WIDTH sweep, 100 MHz, Samsung 28LPP DC topo")
    fig.tight_layout()
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--widths", default=",".join(str(w) for w in DEFAULT_WIDTHS),
                    help="Comma-separated WIDTH values. Default: %(default)s")
    ap.add_argument("--period-ns", type=float, default=DEFAULT_PERIOD_NS,
                    help="Clock period in ns. Default: 10.0 (100 MHz)")
    ap.add_argument("--skip-synth", action="store_true",
                    help="Only parse existing reports and regenerate CSV/plot.")
    ap.add_argument("--rerun-existing", action="store_true",
                    help="Resynthesize points even when area/timing/power reports already exist.")
    args = ap.parse_args()

    widths = parse_widths(args.widths)
    points = [Point(width=w, period_ns=args.period_ns) for w in widths]

    if not args.skip_synth:
        for point in points:
            if reports_complete(point) and not args.rerun_existing:
                print(f"[skip] WIDTH={point.width}: reports already exist")
                continue
            synthesize(point)

    rows = [parse_point(point) for point in points]
    write_csv(rows, HERE / "results.csv")
    plot(rows, HERE / "results.png")

    print("\nWIDTH sweep summary")
    for r in rows:
        print(
            f"  W={r['width']:>4}: {r['status']:<15} "
            f"area={_fmt(r['total_cell_area_um2'], 1e6, 'mm^2')} "
            f"power={_fmt(r['total_power_mw'], 1.0, 'mW')} "
            f"delay={_fmt(r['delay_ns'], 1.0, 'ns')} "
            f"slack={_fmt(r['min_slack_ns'], 1.0, 'ns')}"
        )
    print(f"\nwrote {HERE / 'results.csv'}")
    if (HERE / "results.png").exists():
        print(f"wrote {HERE / 'results.png'}")


def _fmt(value, scale: float, unit: str) -> str:
    if value is None:
        return f"NA {unit}"
    return f"{float(value) / scale:.4g} {unit}"


if __name__ == "__main__":
    main()
