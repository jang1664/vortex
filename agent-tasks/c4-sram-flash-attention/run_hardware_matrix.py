#!/usr/bin/env python3
"""Run full decoder correctness and timing gates on the new SRAM-fusion image.

Invoke with the reference.py Python/environment after sourcing the TVM environment
and configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh.
Hardware execution always uses the repository's
managed ci/run_black.sh hw path. --dry-run only prints commands; it proves no gate.
"""

import argparse
import csv
import hashlib
import json
import math
import os
import re
import shlex
import statistics
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "tests/regression/llama_decoder_C4"
BACKENDS = ("legacy", "resident", "resident-fp32")


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            checksum.update(block)
    return checksum.hexdigest()


def cases():
    result = {}
    for model in ("llama3-8b", "llama2-7b"):
        for past, capacity in ((16, 32), (128, 160), (128, 256)):
            result[f"{model}_decode_p{past}_c{capacity}"] = [
                "--model", model, "--batch", "1", "--seq-len", "1",
                "--stage", "decode", "--past-kv-len", str(past),
                "--cache-capacity", str(capacity)]
    for seq in (16, 128, 144):
        result[f"llama3-8b_prefill{seq}"] = [
            "--model", "llama3-8b", "--batch", "1", "--seq-len", str(seq),
            "--stage", "prefill"]
    return result


def decoder_banner(path):
    banners = [" ".join(line.split()) for line in path.read_text().splitlines()
               if line.startswith("DECODER ")]
    if len(banners) != 1:
        raise ValueError(f"Expected one complete DECODER banner: {path}")
    counts = re.findall(r"\boperations=([0-9]+)\b", banners[0])
    if len(counts) != 1 or int(counts[0]) <= 0:
        raise ValueError(f"Missing/invalid decoder operation count: {path}")
    return banners[0], int(counts[0])


def timing_summary(folder, repetitions, *, verify_folder, verify_log, timing_log):
    verified_banner, expected_count = decoder_banner(verify_log)
    timing_banner, _ = decoder_banner(timing_log)
    if verified_banner != timing_banner:
        raise ValueError(f"Verify/timing decoder graph mismatch: {folder}")
    columns = ("cycles", "attention_total_cycles", "gemm_submit_cycles",
               "gemm_wait_cycles", "sram_copy_cycles", "simd_cycles")

    def profile_rows(path):
        with path.open() as stream:
            rows = list(csv.DictReader(stream))
        for row in rows:
            host_seconds = float(row["host_seconds"])
            if (not row["operation"].strip() or int(row["cycles"]) <= 0
                    or not math.isfinite(host_seconds) or host_seconds <= 0
                    or any(int(row[column]) < 0 for column in columns[1:])):
                raise ValueError(f"Invalid operation profile sample: {path}")
        return rows

    verified = profile_rows(verify_folder / "profile.csv")
    expected_names = [row["operation"] for row in verified]
    if (len(verified) != expected_count or len(set(expected_names)) != expected_count
            or any(int(row["repetition"]) != 0 for row in verified)):
        raise ValueError(f"Incomplete/duplicate verified operation graph: {verify_folder}")
    with (folder / "timings.csv").open() as stream:
        samples = list(csv.DictReader(stream))
    times = [float(row["seconds"]) for row in samples]
    if (repetitions < 1 or [int(row["repetition"]) for row in samples] != list(range(repetitions))
            or any(not math.isfinite(t) or t <= 0 for t in times)):
        raise ValueError(f"Incomplete/invalid timing samples: {folder}")
    profile = profile_rows(folder / "profile.csv")
    expected_order = [(name, repetition) for repetition in range(repetitions) for name in expected_names]
    if [(row["operation"], int(row["repetition"])) for row in profile] != expected_order:
        raise ValueError(f"Incomplete/reordered operation profiles: {folder}")
    operations = defaultdict(list)
    for row in profile:
        operations[row["operation"]].append(row)
    means = {name: {column: statistics.mean(int(row[column]) for row in rows)
                    for column in columns} for name, rows in operations.items()}
    return dict(seconds=times, median_seconds=statistics.median(times),
                operation_mean_cycles=means,
                sum_operation_mean_cycles=sum(row["cycles"] for row in means.values()),
                gemm_wait_includes_input_loads_and_polling=True)


def correctness_summary(folder, require_reference=False, require_backend=False):
    """Require the full-output gates, including reference.py's completion flag."""
    verification = json.loads((folder / "verification.json").read_text())
    if verification.get("pass") is not True or verification.get("elements", 0) <= 0:
        raise ValueError(f"Missing/failed final-output verification: {folder}")
    result = dict(verification=verification, output_sha256=digest(folder / "output.bin"))
    if require_reference:
        reference = json.loads((folder / "intermediate_comparison.json").read_text())
        if (reference.get("pass_all") is not True
                or reference.get("complete_decoder") is not True
                # hybrid_metrics serializes its passing predicate as integer 1.
                or reference.get("chain", {}).get("output", {}).get("pass") != True):
            raise ValueError(f"Incomplete/failed full decoder reference: {folder}")
        result["reference"] = reference
    if require_backend:
        comparison = json.loads((folder / "attention_backend_comparison.json").read_text())
        if comparison.get("pass_all") is not True:
            raise ValueError(f"Failed attention backend comparison: {folder}")
        result["backend_comparison"] = comparison
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", required=True, type=Path)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--fpga-bin", required=True, help="New feature-image alias")
    parser.add_argument("--output", required=True, type=Path, help="New result directory")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--case", action="append", choices=tuple(cases()))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("repetitions must be positive")
    build, fixtures, output = (p.resolve() for p in (args.build, args.fixtures, args.output))
    # run_black.sh forwards one application argument string. Keep its established
    # space-free path contract instead of relying on another layer of shell eval.
    if any(any(c.isspace() for c in str(p)) for p in (build, fixtures, output)):
        parser.error("the blackbox wrapper requires paths without whitespace")
    selected = args.case or list(cases())
    if len(set(selected)) != len(selected):
        parser.error("duplicate case")
    for name in selected:
        for required in ("fixture.json", "reference/output.bin"):
            if not (fixtures / name / required).is_file():
                parser.error(f"missing fixture: {fixtures / name / required}")

    commands = []
    for name in selected:
        for mode in ("verify", "timing"):
            for backend in BACKENDS:
                destination = output / name / mode / backend
                app_args = cases()[name] + [
                    "--mode", mode, "--attention-backend", backend,
                    "--fixture", str(fixtures / name), "--output", str(destination)]
                if mode == "timing":
                    app_args += ["--repetitions", str(args.repetitions)]
                command = [str(build / "ci/run_black.sh"), "hw", "--fpga-bin",
                           args.fpga_bin, "--app", "llama_decoder_C4", "--args",
                           " ".join(app_args)]
                commands.append((f"{name}.{mode}.{backend}", command))
                if mode == "verify":
                    commands.append((f"{name}.reference.{backend}", [
                        sys.executable, str(APP / "reference.py"), "compare",
                        "--fixture", str(fixtures / name), "--output", str(destination)]))
            if mode == "verify":
                for backend in BACKENDS[1:]:
                    commands.append((f"{name}.compare.{backend}", [
                        sys.executable, str(APP / "compare_attention_backends.py"),
                        "--legacy", str(output / name / mode / "legacy"),
                        "--resident", str(output / name / mode / backend)]))
    if args.dry_run:
        for name, command in commands:
            print(f"{name}: {shlex.join(command)}")
        print(f"PLAN ONLY: {len(selected)} cases, {len(commands)} commands; no hardware gates run.")
        return 0

    if not (build / "ci/blackbox.sh").is_file():
        parser.error("use a separate configured hardware build directory")
    alias_map = ROOT / "ci/fpga_bin_alias_map.yaml"
    resolved = subprocess.check_output([
        sys.executable, str(ROOT / "ci/resolve_fpga_bin_alias.py"), args.fpga_bin,
        "--alias-map", str(alias_map)], text=True).splitlines()
    if len(resolved) != 2 or (ROOT / resolved[1]).resolve() != ROOT / "configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh":
        parser.error("alias must select configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh; do not use the old C4 image")
    image_dir = Path(resolved[0])
    image = image_dir if image_dir.suffix == ".xclbin" else image_dir / "vortex_afu.xclbin"
    if not image.is_file():
        parser.error(f"new FPGA image is not available: {image}")
    output.mkdir(parents=True, exist_ok=False)
    log_dir = output / "logs"
    log_dir.mkdir()
    report = dict(scope="full decoder hardware verification and repeated timing",
                  cases=selected, full_nine_case_matrix=len(selected) == len(cases()),
                  backends=BACKENDS, repetitions=args.repetitions, image=str(image),
                  image_sha256=digest(image),
                  alias=args.fpga_bin, config=resolved[1],
                  config_sha256=digest(ROOT / resolved[1]),
                  alias_map_sha256=hashlib.sha256(alias_map.read_bytes()).hexdigest(),
                  passed=False, commands=[], measurements={}, correctness={})
    report_path = output / "matrix.json"

    def save():
        report_path.write_text(json.dumps(report, indent=2) + "\n")

    save()
    try:
        # Pin the same source alias map validated above; configured copies can be
        # older than the new alias. No extra hardware CONFIGS are injected.
        environment = dict(os.environ, VORTEX_FPGA_BIN_ALIAS_MAP=str(alias_map))
        for name, command in commands:
            print(f"RUN {name}", flush=True)
            log = log_dir / f"{name}.log"
            with log.open("x") as stream:
                result = subprocess.run(command, cwd=build, env=environment,
                                        stdout=stream, stderr=subprocess.STDOUT)
            report["commands"].append(dict(name=name, argv=command,
                                           exit_code=result.returncode, log=str(log)))
            save()
            if result.returncode:
                raise RuntimeError(f"{name} failed with exit {result.returncode}; see {log}")
        for name in selected:
            report["correctness"][name] = {
                mode: {backend: correctness_summary(
                    output / name / mode / backend,
                    require_reference=mode == "verify",
                    require_backend=mode == "verify" and backend != "legacy")
                    for backend in BACKENDS}
                for mode in ("verify", "timing")}
            report["measurements"][name] = {
                backend: timing_summary(
                    output / name / "timing" / backend, args.repetitions,
                    verify_folder=output / name / "verify" / backend,
                    verify_log=log_dir / f"{name}.verify.{backend}.log",
                    timing_log=log_dir / f"{name}.timing.{backend}.log")
                for backend in BACKENDS}
        report["passed"] = True
    except Exception as error:
        report["error"] = str(error)
        print(error, file=sys.stderr)
        return 1
    finally:
        save()
    print(f"PASSED requested hardware matrix: {report_path}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
