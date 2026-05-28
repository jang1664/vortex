from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path


def find_repo_root(start: Path) -> Path:
    for path in [start, *start.parents]:
        if (path / "tools" / "fsdb_cli").exists():
            return path
    raise RuntimeError("Repository root not found")


REPO = find_repo_root(Path(__file__).resolve())
if str(REPO / "tools") not in sys.path:
    sys.path.insert(0, str(REPO / "tools"))

import fsdb_cli as fsdb

try:
    import pandas as pd
except ImportError:
    pd = None

BASE_GEMM = "/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_VX_gemm_unit"
BASE_TMEM = "/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_tmem_subsystem"
LDMAS = {
    "input": f"{BASE_TMEM}/u_ldma_input",
    "weight": f"{BASE_TMEM}/u_ldma_weight",
    "sz": f"{BASE_TMEM}/u_ldma_sz",
    "output": f"{BASE_TMEM}/u_ldma_output",
}
IN_FLIGHT = f"{BASE_GEMM}/in_flight"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze MXU/DMA utilization from an FSDB")
    parser.add_argument(
        "--fsdb",
        type=Path,
        default=None,
        help="FSDB path to analyze. If omitted, the script auto-selects a build FSDB with compute activity.",
    )
    parser.add_argument(
        "--show-events",
        type=int,
        default=20,
        help="Number of raw events to print for merger_in_valid in the first compute window",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Optional output CSV path. If set, the metric tables are written there.",
    )
    return parser.parse_args()


def parse_ps_from_info_time(s: str) -> int:
    m = re.findall(r"(\d+)ps", s)
    if m:
        return int(m[-1])
    m = re.findall(r"(\d+)", s)
    if not m:
        raise ValueError(f"Cannot parse time from: {s}")
    return int(m[-1])


def pick_fsdb_with_compute_activity(candidates: list[Path]) -> tuple[Path | None, int]:
    for candidate in candidates:
        if not candidate.exists():
            continue
        active = fsdb.active_time(str(candidate), IN_FLIGHT)
        if active > 0:
            return candidate, active
    return None, 0


def format_table(rows: list[dict]) -> str:
    if not rows:
        return "<empty>"
    headers = list(rows[0].keys())
    widths = {h: len(h) for h in headers}
    for row in rows:
        for h in headers:
            widths[h] = max(widths[h], len(str(row[h])))
    sep = " | "
    header = sep.join(h.ljust(widths[h]) for h in headers)
    rule = "-+-".join("-" * widths[h] for h in headers)
    body = [sep.join(str(row[h]).ljust(widths[h]) for h in headers) for row in rows]
    return "\n".join([header, rule, *body])


def main() -> int:
    args = parse_args()

    lines: list[str] = []

    def emit(msg: str = "") -> None:
        print(msg)
        lines.append(msg)

    if args.fsdb is not None:
        candidates = [args.fsdb]
    else:
        candidates = [
            p for p in sorted((REPO / "build" / "sim" / "xrtsim_vcs").glob("*.fsdb"))
            if p.name != "novas.fsdb"
        ]
    fsdb_path, compute_ps = pick_fsdb_with_compute_activity(candidates)
    if fsdb_path is None:
        raise RuntimeError("No FSDB with observable in_flight activity was found")

    info = fsdb.info(str(fsdb_path))
    total_ps = parse_ps_from_info_time(info.max_time)
    window = fsdb.first_high_window(str(fsdb_path), IN_FLIGHT)

    if window is None:
        bt = None
        et = None
        window_ps = 0
    else:
        bt = f"{window[0]}ps"
        et = f"{window[1]}ps"
        window_ps = window[1] - window[0]

    emit(f"repo={REPO}")
    emit(f"selected fsdb: {fsdb_path}")
    emit(f"info: {info}")
    emit(f"total observed time: {total_ps} ps")
    emit(f"total compute-active time: {compute_ps} ps")
    emit(f"first compute window: {bt} -> {et} ({window_ps} ps)")

    def ratio(sig: str) -> float:
        return fsdb.signal_ratio(str(fsdb_path), sig, IN_FLIGHT)

    def active_ps(sig: str) -> int:
        return fsdb.active_time(str(fsdb_path), sig)

    def row(metric: str, sig: str, force_compute: bool = False) -> dict:
        active = compute_ps if force_compute else active_ps(sig)
        return {
            "metric": metric,
            "signal": sig,
            "active_ps": active,
            "ratio_vs_compute": 1.0 if force_compute else round(ratio(sig), 6),
            "ratio_vs_total": round((active / total_ps) if total_ps else 0.0, 6),
        }

    mxu_rows = [
        row("compute_occupancy", IN_FLIGHT, force_compute=True),
        row("feed_util", f"{BASE_GEMM}/prealigner_out_valid"),
        row("mxu_util", f"{BASE_GEMM}/merger_in_valid"),
        row("scaler_util", f"{BASE_GEMM}/final_scaler_output_valid"),
        row("accum_util", f"{BASE_GEMM}/acc_output_valid[0]"),
        row("fp16_out_util", f"{BASE_GEMM}/fp16_out_valid[0]"),
    ]

    emit("\n[MXU Util]")
    if pd is not None:
        mxu_df = pd.DataFrame(mxu_rows).sort_values("ratio_vs_compute", ascending=False)
        emit(mxu_df.to_string(index=False))
    else:
        emit(format_table(sorted(mxu_rows, key=lambda r: r["ratio_vs_compute"], reverse=True)))

    dma_rows = []
    for name, base in LDMAS.items():
        for edge in ("src_req_fire", "dst_req_fire"):
            sig = f"{base}/{edge}"
            active = active_ps(sig)
            dma_rows.append(
                {
                    "dma": name,
                    "signal": sig,
                    "active_ps": active,
                    "ratio_vs_compute": round(ratio(sig), 6),
                    "ratio_vs_total": round((active / total_ps) if total_ps else 0.0, 6),
                }
            )

    emit("\n[DMA Util]")
    if pd is not None:
        dma_df = pd.DataFrame(dma_rows).sort_values(["dma", "signal"])
        emit(dma_df.to_string(index=False))
    else:
        emit(format_table(sorted(dma_rows, key=lambda r: (r["dma"], r["signal"]))))

    report_bt = bt if bt is not None else None
    report_et = et if et is not None else None
    raw = fsdb.report(str(fsdb_path), [f"{BASE_GEMM}/merger_in_valid", IN_FLIGHT], bt=report_bt, et=report_et)
    events = raw.events()[: args.show_events]

    emit("\n[Raw Events]")
    for event in events:
        emit(str(event))

    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        csv_rows = []
        for item in mxu_rows:
            csv_rows.append(
                {
                    "section": "mxu",
                    "name": item["metric"],
                    "signal": item["signal"],
                    "active_ps": item["active_ps"],
                    "ratio_vs_compute": item["ratio_vs_compute"],
                    "ratio_vs_total": item["ratio_vs_total"],
                }
            )
        for item in dma_rows:
            csv_rows.append(
                {
                    "section": "dma",
                    "name": item["dma"],
                    "signal": item["signal"],
                    "active_ps": item["active_ps"],
                    "ratio_vs_compute": item["ratio_vs_compute"],
                    "ratio_vs_total": item["ratio_vs_total"],
                }
            )
        with args.output.open("w", newline="") as f:
            writer = csv.DictWriter(
                f,
                fieldnames=[
                    "section",
                    "name",
                    "signal",
                    "active_ps",
                    "ratio_vs_compute",
                    "ratio_vs_total",
                ],
            )
            writer.writeheader()
            writer.writerows(csv_rows)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
