#!/usr/bin/env python3
"""Analyze candidate FPGA totals and hierarchy breakdowns, reports first."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
from typing import Sequence
from yaml import YAMLError

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT))

from tools.latency_bench.fpga_bins import load_fpga_bin_aliases, resolve_fpga_bin_config
from tools.latency_bench.yaml_io import safe_load

if __package__:
    from .util_reports import Analysis, CATEGORIES, RESOURCES, analyze_report, checkpoint_candidates, implementation_dir, select_report
else:
    from util_reports import Analysis, CATEGORIES, RESOURCES, analyze_report, checkpoint_candidates, implementation_dir, select_report

FIELDS = ("candidate", "stage", "resource", "used", "available", "device_pct", "source", "fallback", "status")
EXTRACT_TCL = """set_param general.maxThreads 4
lassign $argv input action output run_name also_breakdown
if {[file extension $input] eq ".xpr"} {
    open_project -read_only $input
    open_run $run_name
} else {
    open_checkpoint -ignore_timing $input
}
if {$action eq "total"} {
    report_utilization -file $output
    if {$also_breakdown eq "1"} {
        # Preserve a valid total even if the optional hierarchy export fails.
        if {[catch {
            report_utilization -hierarchical -hierarchical_depth 100 -hierarchical_min_primitive_count 0 -file [file join [file dirname $output] breakdown.rpt]
        } detail]} {
            puts stderr "BREAKDOWN_EXPORT_FAILED: $detail"
        }
    }
} else {
    report_utilization -hierarchical -hierarchical_depth 100 -hierarchical_min_primitive_count 0 -file $output
}
close_design
exit
"""


def list_argument(values: Sequence[str]) -> list[str]:
    return list(dict.fromkeys(part.strip() for value in values for part in value.split(",") if part.strip()))


def load_candidates(config: Path, alias_map: Path | None) -> dict[str, Path]:
    with config.open() as stream:
        document = safe_load(stream)
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise ValueError("candidate config must have schema_version: 1")
    candidates = document.get("candidates")
    if not isinstance(candidates, dict) or not candidates:
        raise ValueError("candidate config must contain a non-empty candidates mapping")
    aliases = load_fpga_bin_aliases(alias_map)
    result = {}
    for name, value in candidates.items():
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", name):
            raise ValueError(f"invalid candidate name: {name!r}")
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"candidate {name} must be an alias or non-empty path string")
        value = value.strip()
        if value not in aliases:
            path = Path(value).expanduser()
            # A bare unknown name is probably a misspelled alias, not a build directory.
            if not path.is_absolute() and "/" not in value and not (ROOT / path).is_dir():
                raise ValueError(f"unknown FPGA alias: {value}")
            value = str(path if path.is_absolute() else ROOT / path)
        resolved = resolve_fpga_bin_config(value, aliases=aliases).path
        result[name] = resolved.parent if resolved.name == "bin" else resolved
    return result


def run_vivado(command: list[str], work: Path, stream) -> int:
    # Vivado's launcher is a shell with child processes; timeout must stop the whole group.
    with subprocess.Popen(command, cwd=work, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True) as process:
        try:
            return process.wait(timeout=1800)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise


def extract_report(build: Path, candidate: str, action: str, out: Path, vivado: str, notes: list[str], also_breakdown: bool = False) -> tuple[Analysis | None, list[str]]:
    inputs = [(path, stage, "impl_1") for path, stage in checkpoint_candidates(build, action)]
    project = implementation_dir(build).parent.parent / "prj.xpr"
    if project.is_file():
        # XPR is an alternative entrypoint into saved runs, never a request to launch a run.
        inputs.append((project, "unknown", "impl_1"))
        if action == "breakdown":
            inputs.append((project, "synth", "ulp_vortex_afu_1_0_synth_1"))
    for index, (source, stage, run) in enumerate(inputs):
        report_dir = out / "reports" / candidate
        report_dir.mkdir(parents=True, exist_ok=True)
        # Fresh paths prevent a failed extraction from accepting a previous run's report.
        work = Path(tempfile.mkdtemp(prefix=f"{action}_{index}_{stage}_", dir=report_dir))
        script = work / "extract.tcl"
        report_path = work / f"{action}.rpt"
        script.write_text(EXTRACT_TCL)
        log = work / "console.log"
        print(f"{candidate} {action}: export {source} ({stage}); log: {log}", flush=True)
        started = False
        try:
            with log.open("w") as stream:
                returncode = run_vivado(
                    [vivado, "-mode", "batch", "-source", str(script), "-log", "vivado.log", "-journal", "vivado.jou",
                     "-tclargs", str(source), action, str(report_path), run, str(int(also_breakdown))],
                    work, stream,
                )
            started = True
            if returncode:
                raise ValueError(f"Vivado exited {returncode}; see {log}")
            analysis = analyze_report(report_path, action, stage, True)
            if stage == "unknown":
                # Inspect the checkpoint Vivado actually read, not a shell's Design State.
                checkpoint_line = next((line for line in log.read_text(errors="replace").splitlines()
                                        if "Reading checkpoint" in line and ".dcp" in line), "")
                for token in ("postroute_physopt", "routed", "physopt", "placed", "opt"):
                    if f"_{token}.dcp" in checkpoint_line:
                        analysis.stage = token
                        break
            analysis.notes = [*notes, f"No usable report; exported from {source} (run {run}). See {log}"]
            analysis.checkpoint = source
            return analysis, analysis.notes
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            notes.append(f"Extraction failed for {source} (run {run}): {exc}")
            if isinstance(exc, FileNotFoundError) and not started:
                break
    notes.append(f"No usable {action} report or saved checkpoint for {build}")
    return None, notes


def analysis_rows(candidate: str, action: str, analysis: Analysis | None) -> list[dict]:
    rows = []
    categories = ("Full FPGA",) if action == "total" else CATEGORIES
    for category in categories:
        for resource in RESOURCES:
            row = dict(candidate=candidate, stage="", resource=resource, used="", available="", device_pct="",
                       source="", fallback="true", status="unavailable")
            if action == "breakdown":
                row["category"] = category
            if analysis:
                used, available = analysis.values[category][resource], analysis.capacity[resource]
                row.update(stage=analysis.stage, used=used, available=available, device_pct=100 * used / available,
                           source=str(analysis.report.path), fallback=str(analysis.fallback).lower(), status="ok")
            rows.append(row)
    return rows


def save_csv(path: Path, action: str, rows: list[dict]) -> None:
    fields = list(FIELDS)
    if action == "breakdown":
        fields.insert(2, "category")
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def markdown_cell(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def render_summary(rows: dict[str, list[dict]], provenance: list[tuple[str, str, Analysis | None, list[str]]]) -> str:
    lines = ["# Candidate FPGA utilization", "", f"Generated: {datetime.now().astimezone().isoformat(timespec='seconds')}", "",
             "Percentages use full FPGA capacity. Total includes the shell; breakdown covers Vortex_axi only.",
             "BRAM is measured in 36 Kb tiles (RAMB36 + RAMB18 / 2). TCU is included in SIMT.",
             "Hierarchy percentages from Vivado are ignored because they may use partition capacity.", ""]
    for action, records in rows.items():
        lines.extend([f"## {action.capitalize()}", ""])
        headings = ["Candidate", "Stage", "Fallback"] + (["Category"] if action == "breakdown" else []) + list(RESOURCES)
        lines.append("| " + " | ".join(headings) + " |")
        lines.append("| " + " | ".join("---" for _ in headings) + " |")
        grouped = {}
        for row in records:
            key = (row["candidate"], row.get("category", ""))
            grouped.setdefault(key, {})[row["resource"]] = row
        for (candidate, category), resources in grouped.items():
            sample = resources[RESOURCES[0]]
            cells = [candidate, sample["stage"] or "unavailable", sample["fallback"]]
            if action == "breakdown":
                cells.append(category)
            for resource in RESOURCES:
                row = resources[resource]
                cells.append(f"{row['used']:,.1f} ({row['device_pct']:.2f}%)" if row["status"] == "ok" else "N/A")
            lines.append("| " + " | ".join(map(markdown_cell, cells)) + " |")
        lines.append("")
    lines.extend(["## Sources and fallback decisions", ""])
    for candidate, action, analysis, notes in provenance:
        lines.extend([f"### {candidate}: {action}", ""])
        if analysis:
            report = analysis.report
            lines.append(f"- Stage: `{analysis.stage}`; source: `{report.path}`")
            lines.append(f"- Report device: `{report.header.get('Device', 'unknown')}`; raw Design State: `{report.header.get('Design State', 'unknown')}`")
            if "-hierarchical" in report.header.get("Command", ""):
                lines.append("- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.")
            if analysis.checkpoint:
                lines.append(f"- Extracted from: `{analysis.checkpoint}`")
        else:
            lines.append("- Unavailable; empty CSV counts represent missing data, not zero usage.")
        lines.extend(f"- {markdown_cell(note)}" for note in notes)
        lines.append("")
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidates", nargs="+", help="Candidate names, comma or space separated (default: all YAML candidates)")
    parser.add_argument("--action", nargs="+", default=["total", "breakdown"], help="total and/or breakdown, comma or space separated")
    parser.add_argument("--config", type=Path, default=HERE / "candidate_fpga_bins.yaml")
    parser.add_argument("--alias-map", type=Path, default=None, help="Alias map (default: existing resolver's environment/default map)")
    parser.add_argument("--output-dir", type=Path, default=HERE / "results")
    parser.add_argument("--vivado", default="vivado", help="Vivado executable for missing-report extraction")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        candidates = load_candidates(args.config.expanduser().resolve(), args.alias_map)
        selected = list_argument(args.candidates) if args.candidates is not None else list(candidates)
        actions = list_argument(args.action)
        if not selected or any(name not in candidates for name in selected):
            raise ValueError(f"unknown or empty candidates: {selected}; known candidates: {list(candidates)}")
        if not actions or any(action not in ("total", "breakdown") for action in actions):
            raise ValueError("--action must contain total and/or breakdown")
    except (OSError, ValueError, YAMLError) as exc:
        parser.error(str(exc))
    out = args.output_dir.expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    rows = {action: [] for action in actions}
    provenance = []
    failed = False
    # Sequential extraction limits memory usage when opening large checkpoints.
    for candidate in selected:
        chosen = {action: select_report(candidates[candidate], action) for action in actions}
        for action in (name for name in ("total", "breakdown") if name in actions):
            analysis, notes = chosen[action]
            if analysis is None:
                together = action == "total" and "breakdown" in chosen and chosen["breakdown"][0] is None
                analysis, notes = extract_report(candidates[candidate], candidate, action, out, args.vivado, notes, together)
                if analysis and together:
                    hierarchy_path = analysis.report.path.parent / "breakdown.rpt"
                    hierarchy_notes = chosen["breakdown"][1]
                    try:
                        hierarchy = analyze_report(hierarchy_path, "breakdown", analysis.stage, True)
                        hierarchy.checkpoint = analysis.checkpoint
                        hierarchy.notes = [*hierarchy_notes, f"No usable report; exported hierarchy together with total from {analysis.checkpoint}."]
                        chosen["breakdown"] = hierarchy, hierarchy.notes
                    except (OSError, ValueError) as exc:
                        hierarchy_notes.append(f"Combined hierarchy export unavailable: {exc}")
            if analysis:
                print(f"{candidate} {action}: {analysis.stage}, fallback={analysis.fallback}, {analysis.report.path}", flush=True)
            else:
                failed = True
                print(f"{candidate} {action}: unavailable; {notes[-1]}", file=sys.stderr)
            rows[action].extend(analysis_rows(candidate, action, analysis))
            provenance.append((candidate, action, analysis, notes))
    for action, records in rows.items():
        save_csv(out / f"{action}.csv", action, records)
    (out / "summary.md").write_text(render_summary(rows, provenance))
    print(f"Results: {out}", flush=True)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
