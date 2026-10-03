"""Stage selected remeasurements and publish successful physical rows only."""
from __future__ import annotations

import argparse
import csv
import hashlib
from dataclasses import replace
import json
import os
from pathlib import Path
import shlex
import sys
from datetime import datetime, timezone

from .kernel_variants import parse_variants
from .raw_db import _measurement_key_from_row, _normalize_args, _write_raw_rows
from .suite import BenchCase, BenchSuite, apply_case_filters, load_suite, suite_to_expanded_yaml
from .suite_io import write_suite_payload


def row_signature(row: dict) -> str:
    return hashlib.sha256(json.dumps(row, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def selected_suite(suite: BenchSuite, raw_db: Path, filters: tuple[str, ...],
                   label: str, stage: str) -> BenchSuite:
    cases = list(suite.cases)
    current_apps = {case.app for case in cases}
    seen = {(c.app, _normalize_args(c.measurement_args or c.args)) for c in cases if c.measurement_kind == "measured"}
    snapshot = suite.experiment.get("candidates", {}).get(label, {})
    archive_cache = {}
    if raw_db.is_file():
        with raw_db.open(newline="") as source:
            for row in csv.DictReader(source):
                # Historical probes may extend a current kernel's shapes, but
                # cannot resurrect apps removed or routed to another FPGA.
                if row.get("app") not in current_apps:
                    continue
                if row.get("fpga_bin_label") != label:
                    continue
                if snapshot and row.get("xclbin_sha256") != snapshot["xclbin_sha256"]:
                    continue
                key = row["app"], _normalize_args(row["args"])
                if key in seen:
                    continue
                run_id = row.get("run_id", "")
                if run_id not in archive_cache:
                    index = {}
                    archive = raw_db.parent / "runs" / run_id / "cases.csv"
                    if archive.is_file():
                        with archive.open(newline="") as saved:
                            for case in csv.DictReader(saved):
                                index[(case["app"], _normalize_args(case.get("measurement_args") or case["args"]))] = case
                    archive_cache[run_id] = index
                saved = archive_cache[run_id].get(key, {})
                row_stage = saved.get("stage") or row.get("stage")
                if row_stage not in ("prefill", "generation") and row["app"] in ("softmax_layout_fused", "kv_cache_quant_layout_fused_w4a16"):
                    tokens = shlex.split(row["args"])
                    decode = "append" in tokens or ("-seqq" in tokens and tokens[tokens.index("-seqq") + 1] == "1")
                    row_stage = "generation" if decode else "prefill"
                if row_stage != stage:
                    continue
                seen.add(key)
                cases.append(BenchCase(
                    case_id="rerun_" + row["exec_key"], app=row["app"], args=row["args"],
                    stage=stage, backend=saved.get("backend", ""), name=saved.get("name", ""),
                    warmup=suite.defaults.warmup, iterations=suite.defaults.iterations,
                    fpga_bin=label, xclbin_sha256=row.get("xclbin_sha256", ""),
                    source="historical_raw_db", padded_args=row.get("padded_args", ""),
                ))
    return apply_case_filters(replace(suite, cases=cases,
        source_expanded_snapshot_reusable=False), filters)


def merge_successful_rows(staged: Path, destination: Path, run_id: str,
                          allowed_apps: set[str] | None = None) -> dict:
    with staged.open(newline="") as source:
        rows = list(csv.DictReader(source))
    successful = [row for row in rows if row["status"] == "pass"
                  and (allowed_apps is None or row["app"] in allowed_apps)]
    before = []
    if destination.exists():
        with destination.open(newline="") as source:
            before = list(csv.DictReader(source))
    keys = {_measurement_key_from_row(row) for row in successful}
    untouched = [row for row in before if _measurement_key_from_row(row) not in keys]
    replaced = _write_raw_rows(successful, destination, mode="replace", run_id=run_id)
    with destination.open(newline="") as source:
        after = list(csv.DictReader(source))
    assert [row for row in after if _measurement_key_from_row(row) not in keys] == untouched
    failed = [row for row in rows if row["status"] not in ("pass", "")]
    unfinished = [row for row in rows if not row["status"]]
    return dict(successful=len(successful), failed=len(failed), unfinished=len(unfinished),
                ignored_successful=sum(row["status"] == "pass" for row in rows) - len(successful),
                replaced=replaced, preserved=len(untouched),
                failed_exec_keys=[row["exec_key"] for row in failed])


def pending_suite(suite: BenchSuite, raw_db: Path, options) -> tuple[BenchSuite, int]:
    """Keep only measurements not reusable under the normal strict contract."""
    from .runner import (build_execution_units, evaluate_measurement_coverage,
                         strict_measurement_policy, MeasurementReuseState)
    candidate = suite.experiment["candidates"][options.fpga_bin_label]
    policy = strict_measurement_policy(suite, options, xclbin_sha256=candidate["xclbin_sha256"])
    coverage = evaluate_measurement_coverage(raw_db, build_execution_units(suite, raw_db.parent / "inspection"), policy)
    reusable = {item.exec_key for item in coverage.evidence if item.state is MeasurementReuseState.REUSE}
    return replace(suite, cases=[case for case in suite.cases if case.exec_key not in reusable]), len(reusable)


def publish_staged(staging: Path, out: Path, allowed_apps: set[str] | None = None) -> dict:
    """Publish completed rows, including after an interrupted allocation."""
    if not (staging / "raw_db.csv").is_file():
        return {"successful": 0, "run_kernel_variants": {}}
    # Move complete evidence before publishing its absolute paths into the main DB.
    import shutil
    published = out / "runs"
    published.mkdir(exist_ok=True)
    run_metadata = {}
    for run in list((staging / "runs").iterdir()) if (staging / "runs").is_dir() else []:
        target = published / run.name
        if target.exists():
            raise RuntimeError(f"run ID collision: {target}")
        shutil.move(str(run), str(target))
        old, new = str(run), str(target)
        for path in target.rglob("*"):
            if path.is_file() and path.suffix in (".json", ".csv", ".yaml"):
                text = path.read_text()
                if old in text:
                    path.write_text(text.replace(old, new))
        database = staging / "raw_db.csv"
        text = database.read_text()
        database.write_text(text.replace(old, new))
        variant_file = target / "kernel_variants.json"
        if variant_file.is_file():
            run_metadata[run.name] = json.loads(variant_file.read_text())["apps"]
    summary = merge_successful_rows(staging / "raw_db.csv", out / "raw_db.csv", staging.name, allowed_apps)
    summary["benchmark_value_check"] = False
    summary["run_kernel_variants"] = run_metadata
    (staging / "rerun_summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    metadata_path = out / "kernel_variants.json"
    recorded = json.loads(metadata_path.read_text()) if metadata_path.exists() else {"schema_version": 1, "runs": {}}
    recorded["runs"].update(run_metadata)
    metadata_path.write_text(json.dumps(recorded, indent=2, sort_keys=True) + "\n")
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--stage", required=True)
    parser.add_argument("--fpga-bin", required=True)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--filter", action="append", default=[])
    parser.add_argument("--kernel-variant", action="append", default=[])
    parser.add_argument("--application-source-identity", required=True)
    parser.add_argument("--warmup", type=int, default=0)
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--blackbox-timeout", default="24h",
                        help="per-case timeout, matching run_fpga_bin.sh (default: 24h)")
    parser.add_argument("--skip-power-app", action="append", default=[])
    parser.add_argument("--power-idle-stability-policy", type=Path)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    repo = Path(__file__).resolve().parents[2]
    parse_variants(args.kernel_variant, repo)
    original = load_suite(args.suite, repo_root=repo, warmup_override=args.warmup,
                          iterations_override=args.iterations)
    suite = selected_suite(original, args.out / "raw_db.csv", tuple(args.filter), args.fpga_bin, args.stage)
    summary = dict(stage=args.stage, apps=sorted({c.app for c in suite.cases}),
                   unique_executions=len({c.exec_key for c in suite.cases if c.measurement_kind == "measured"}),
                   kernel_variants=args.kernel_variant, power_skip_apps=args.skip_power_app, force=args.force)
    if not args.force and suite.cases:
        from .runner import RunOptions
        candidate = suite.experiment["candidates"][args.fpga_bin]
        options = RunOptions(
            build_dir=args.build_dir, fpga_bin_dir=Path(candidate["bin_dir"]),
            out_dir=args.out, platform=suite.defaults.platform, fpga_bin_label=args.fpga_bin,
            configs=Path(candidate["config"]), strict_measurement_reuse=True, adopt_legacy=True,
            application_source_identity=args.application_source_identity,
            kernel_variants=tuple(args.kernel_variant), skip_existing=True,
            power_skip_apps=tuple(args.skip_power_app),
            power_auto_duration=False, power_min_interval=0.01, power_latency_interval=0.1,
            power_idle_stability_policy=args.power_idle_stability_policy or
                repo / "analysis_workspace/latency_on_hw/idle_stability_policy.json",
            power_kernel_iterations=1, power_kernel_iterations_auto=True, power_target_sec=10.0,
        )
        suite, summary["reused"] = pending_suite(suite, args.out / "raw_db.csv", options)
        summary["pending_executions"] = len({case.exec_key for case in suite.cases if case.measurement_kind == "measured"})
    if args.dry_run or not suite.cases:
        print(json.dumps(summary, sort_keys=True))
        return 0
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    staging = args.out / "remeasurements" / f"{args.stage}.{stamp}"
    staging.mkdir(parents=True)
    if (args.out / "raw_db.csv").is_file():
        import shutil
        shutil.copy2(args.out / "raw_db.csv", staging / "raw_db.before.csv")
    aliases = staging / "frozen_aliases.yaml"
    write_suite_payload(aliases, {"aliases": {
        spec["alias"]: {"path": spec["bin_dir"], "configs": spec["config"]}
        for spec in suite.experiment.get("candidates", {}).values()
    }})
    suite_file = staging / "suite.pkl"
    write_suite_payload(suite_file, suite_to_expanded_yaml(suite))
    command = ["run", "--suite", str(suite_file), "--out", str(staging),
               "--build-dir", str(args.build_dir), "--fpga-bin", args.fpga_bin,
               "--warmup", str(args.warmup), "--iterations", str(args.iterations),
               "--strict-measurement-reuse", "--skip-existing", "--adopt-legacy",
               "--application-source-identity", args.application_source_identity,
               "--power-kernel-iterations", "auto", "--power-target-sec", "10",
               "--power-latency-interval", "0.1", "--no-power-auto-duration",
               "--power-idle-stability-policy", str(args.power_idle_stability_policy or
                    repo / "analysis_workspace/latency_on_hw/idle_stability_policy.json"),
               "--blackbox-timeout", args.blackbox_timeout, "--retry", "--retry-max-rounds", "2",
               "--retry-timeout-growth", "1.01"]
    if os.environ.get("SLURM_JOB_ID"):
        command.append("--no-srun")
    for app in args.skip_power_app:
        command.extend(["--skip-power-app", app])
    for value in args.kernel_variant:
        command.extend(["--kernel-variant", value])
    from .cli import main as bench_main
    prior_alias_map = os.environ.get("VORTEX_FPGA_BIN_ALIAS_MAP")
    if suite.experiment:
        os.environ["VORTEX_FPGA_BIN_ALIAS_MAP"] = str(aliases.resolve())
    import signal
    previous_handler = signal.getsignal(signal.SIGTERM)
    def interrupted(signum, frame):
        raise KeyboardInterrupt("allocation terminated")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        try:
            result = bench_main(command)
        except KeyboardInterrupt:
            result = 130
            summary["interrupted"] = True
    finally:
        signal.signal(signal.SIGTERM, previous_handler)
        if prior_alias_map is None:
            os.environ.pop("VORTEX_FPGA_BIN_ALIAS_MAP", None)
        else:
            os.environ["VORTEX_FPGA_BIN_ALIAS_MAP"] = prior_alias_map
    summary.update(publish_staged(staging, args.out))
    (staging / "rerun_summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, sort_keys=True))
    return result


if __name__ == "__main__":
    raise SystemExit(main())
