#!/usr/bin/env python3
"""Compare archived synthesis against utilization read from final routed DCPs.

Run with --extract to generate missing reports; omit it to rebuild CSVs/plots.
Existing reports are reused. No synthesis or implementation commands are run.
"""
import argparse
import concurrent.futures
import csv
import json
import os
import re
import subprocess
import time
from pathlib import Path

import yaml

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
SYNTH = "ulp_vortex_afu_1_0_synth_1_ulp_vortex_afu_1_0_utilization_synth.rpt"
METRICS = {
    "LUT": "CLB LUTs",
    "Logic LUT": "LUT as Logic",
    "Memory LUT": "LUT as Memory",
    "FF": "CLB Registers",
    "BRAM tile": "Block RAM Tile",
    "RAMB36": "RAMB36/FIFO",
    "RAMB18": "RAMB18",
    "URAM": "URAM",
    "DSP": "DSPs",
    "CLB": "CLB",
}


def read_report(path):
    result = {"path": str(path), "metrics": {}, "header": {}}
    if not path.exists():
        return result
    with path.open() as stream:
        for number, line in enumerate(stream, 1):
            cells = [s.strip() for s in line.strip().strip("|").split("|")]
            if not line.startswith("|"):
                continue
            if len(cells) == 1 and ":" in cells[0]:
                key, value = cells[0].split(":", 1)
                result["header"][key.strip()] = value.strip()
            if len(cells) != 6:
                continue
            site = cells[0].rstrip("*").strip()
            for metric, label in METRICS.items():
                if site != label or metric in result["metrics"]:
                    continue
                try:
                    used = float(cells[1].replace(",", ""))
                    available = float(cells[4].replace(",", ""))
                except ValueError:
                    continue
                result["metrics"][metric] = {
                    "used": used, "available": available, "line": number,
                    "util_pct": 100 * used / available if available else None,
                }
    return result


def designs():
    aliases = yaml.safe_load((ROOT / "ci/fpga_bin_alias_map.yaml").read_text())["aliases"]
    grouped = {}
    for alias, value in aliases.items():
        grouped.setdefault(value["path"], []).append((alias, value["configs"]))
    result = []
    for binary, members in grouped.items():
        short = next((a for a, _ in members if re.fullmatch(r"C\d(?:_.*)?", a)), members[0][0])
        directory = Path(binary).parent
        impl = directory / "_x/link/vivado/vpl/prj/prj.runs/impl_1"
        checkpoints = list(impl.glob("*postroute_physopt.dcp")) or list(impl.glob("*routed.dcp"))
        item = {
            "design": short, "aliases": [a for a, _ in members],
            "config": members[0][1], "binary_path": binary,
            "checkpoint": str(checkpoints[0]) if len(checkpoints) == 1 else None,
            "reports_dir": str(OUT / "reports" / short),
            "status": "missing_alias_path" if not directory.exists() else "missing_final_checkpoint" if not checkpoints else "checkpoint_available",
        }
        manifest = directory / "manifest.json"
        if manifest.exists():
            data = json.loads(manifest.read_text())
            item["build_id"] = data.get("id", {}).get("full")
            item["build_params"] = data.get("params", {})
        result.append(item)
    return result


def extract(item):
    if not item["checkpoint"]:
        return
    dest = Path(item["reports_dir"])
    dest.mkdir(parents=True, exist_ok=True)
    # Allow resuming a runner while its already-started reporting children finish.
    # Avoid reopening or overwriting the reports of an active Vivado process.
    while True:
        active = False
        for entry in Path('/proc').iterdir():
            if not entry.name.isdigit() or int(entry.name) == os.getpid():
                continue
            try:
                if (entry / 'cwd').resolve() == dest and (entry / 'comm').read_text().strip() == 'vivado':
                    active = True
                    break
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                continue
        if not active:
            break
        time.sleep(5)
    if all((dest / name).exists() for name in ["kernel_postroute_utilization.rpt", "full_postroute_utilization.rpt"]):
        print(f"Reuse {item['design']}", flush=True)
        return
    checkpoint = item["checkpoint"]
    assert not any(c in checkpoint for c in "{}\n")
    (dest / "extract.tcl").write_text(
        "set_param general.maxThreads 4\n"
        f"open_checkpoint -ignore_timing {{{checkpoint}}}\n"
        "set kernel [get_cells -quiet level0_i/ulp/vortex_afu_1]\n"
        'if {[llength $kernel] != 1} {error "Expected one Vortex kernel"}\n'
        "report_utilization -cells $kernel -file {kernel_postroute_utilization.rpt}\n"
        "report_utilization -file {full_postroute_utilization.rpt}\n"
        "close_design\nexit\n"
    )
    print(f"Extract {item['design']}", flush=True)
    with (dest / "console.log").open("w") as log:
        completed = subprocess.run(
            ["bash", "-c", 'source "$1"; exec vivado -mode batch -source extract.tcl -log extract.log -journal extract.jou',
             "vivado-report", str(ROOT / item["config"])],
            cwd=dest, stdout=log, stderr=subprocess.STDOUT, timeout=1800,
        )
    if completed.returncode:
        raise RuntimeError(f"Vivado failed for {item['design']}; see {dest / 'console.log'}")
    print(f"Done {item['design']}", flush=True)


def save_csv(path, rows):
    fields = list(dict.fromkeys(k for row in rows for k in row))
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def analyze(items):
    comparisons, stage_rows = [], []
    for item in items:
        binary = Path(item["binary_path"])
        directory = binary.parent
        impl = directory / "_x/link/vivado/vpl/prj/prj.runs/impl_1"
        init = impl / "init_report_utilization_0.rpt"
        if not init.exists():
            init = directory / "_x/reports/link/imp/impl_1_init_report_utilization_0.rpt"
        final_dir = Path(item["reports_dir"])
        reports = {
            "kernel_synth": read_report(binary / SYNTH),
            "kernel_final": read_report(final_dir / "kernel_postroute_utilization.rpt"),
            "full_linked_pre_opt": read_report(init),
            "full_placed": read_report(binary / "impl_1_hw_bb_locked_utilization_placed.rpt"),
            "full_final": read_report(final_dir / "full_postroute_utilization.rpt"),
        }
        item["report_metadata"] = {stage: {k: v for k, v in r.items() if k != "metrics"} for stage, r in reports.items()}
        if reports["kernel_final"]["metrics"]:
            item["status"] = "complete"
        for stage, report in reports.items():
            for resource, values in report["metrics"].items():
                stage_rows.append({"design": item["design"], "stage": stage, "resource": resource, **values,
                                   "report": report["path"]})
        pairs = [("kernel", "kernel_synth", "kernel_final"),
                 ("full", "full_linked_pre_opt", "full_final"),
                 ("full_to_placed", "full_linked_pre_opt", "full_placed")]
        for scope, before, after in pairs:
            for resource in METRICS:
                s = reports[before]["metrics"].get(resource)
                p = reports[after]["metrics"].get(resource)
                if not s or not p:
                    continue
                assert s["available"] == p["available"], (item["design"], resource, s, p)
                delta = p["used"] - s["used"]
                comparisons.append({
                    "design": item["design"], "aliases": ";".join(item["aliases"]), "scope": scope,
                    "resource": resource, "synth_or_linked_used": s["used"], "postroute_used": p["used"],
                    "delta_used": delta, "relative_change_pct": 100 * delta / s["used"] if s["used"] else None,
                    "available": s["available"], "before_util_pct": s["util_pct"],
                    "postroute_util_pct": p["util_pct"], "util_delta_pp": p["util_pct"] - s["util_pct"],
                    "before_report": reports[before]["path"], "postroute_report": reports[after]["path"],
                })
    save_csv(OUT / "comparison.csv", comparisons)
    save_csv(OUT / "stages.csv", stage_rows)
    save_csv(OUT / "alias_coverage.csv", [{"alias": a, "design": i["design"], "status": i["status"], "binary_path": i["binary_path"]} for i in items for a in i["aliases"]])
    (OUT / "inventory.json").write_text(json.dumps(items, indent=2) + "\n")
    return comparisons


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extract", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    inventory = designs()
    if args.extract:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            list(pool.map(extract, inventory))
    rows = analyze(inventory)
    print(f"Compared {sum(i['status'] == 'complete' for i in inventory)}/{len(inventory)} unique designs; {len(rows)} resource pairs.")
