#!/usr/bin/env python3
"""Run the frozen W4 GEMM comparison matrix through ci/run_black.sh.

Use a newly configured, isolated build for each RTL revision. This script does
not clean, configure, modify RTL, or run synthesis. Raw traces remain in the
selected output directory, compressed after deterministic streaming checks.
"""

import argparse
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


CASES = {
    "smoke_qcol": "-m 2 -n 32 -k 128 -q 32 -t 0 -d 0 -r 1",
    "overlap_qcol": "-m 4 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1",
    "qrow": "-m 31 -n 64 -k 96 -q 32 -t 1 -d 1 -r 1",
    "odd_tail_qcol": "-m 3 -n 33 -k 33 -q 32 -t 0 -d 0 -r 1",
}
EXTRA_CONFIGS = " ".join([
    "-DDBG_TRACE_PIPELINE", "-DDBG_TRACE_MEM", "-DDBG_TRACE_CACHE",
    "-DDBG_TRACE_AFU", "-DDBG_TRACE_SCOPE", "-DDBG_TRACE_GBAR",
    "-DDBG_TRACE_TCU", "-DDBG_TRACE_GEMM",
    "-DDISABLE_FSDB",
])


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def trace_metrics(path, verifier):
    times = {key: [] for key in ("input_accept", "compute_fire", "dma_accept", "dma_complete")}
    commands = []
    dma_accepts = []
    failures = []
    slot_metrics = {}
    with path.open(errors="replace") as stream:
        for number, line in enumerate(stream, 1):
            if verifier.has_strict_failure(line) or re.search(r"Assertion.*failed|assertion failure|^Error-", line, re.I):
                failures.append({"line": number, "text": line.rstrip()[:800]})
            slot_event = re.search(r"(\S+) SLOT_(ALLOC|RESPONSE|RELEASE|SUMMARY)\s", line)
            if slot_event:
                instance, event = slot_event.groups()
                slot_record = slot_metrics.setdefault(instance, {
                    "request_to_response_cycles": [], "allocation_to_release_cycles": [],
                    "allocation_events": 0, "same_cycle_recycles": 0,
                    "response_bypass_releases": 0,
                })
                fields = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", line)}
                if event == "ALLOC":
                    slot_record["allocation_events"] += 1
                    slot_record["same_cycle_recycles"] += fields["recycle"]
                elif event == "RESPONSE":
                    slot_record["request_to_response_cycles"].append(fields["request_to_response"])
                elif event == "RELEASE":
                    slot_record["allocation_to_release_cycles"].append(fields["allocation_to_release"])
                    slot_record["response_bypass_releases"] += fields.get("response_bypass", 0)
                elif event == "SUMMARY":
                    slot_record["final_summary"] = fields
            match = re.search(r":\s*\[(\d+)\]\s*\|", line)
            if match:
                timestamp = int(match[1])
                if "GEMM_V2_OWNERSHIP |" in line and "accept=1," in line:
                    times["input_accept"].append(timestamp)
                if "GEMM_V2_COMPUTE_FIRE |" in line:
                    times["compute_fire"].append(timestamp)
                if "TMEM_DMA_CMD_ACCEPT |" in line:
                    times["dma_accept"].append(timestamp)
                    dma_accepts.append({"timestamp": timestamp, **dict(re.findall(r"(\w+)=([^,}]+)", line))})
                if "TMEM_DMA_LOGICAL_COMPLETE |" in line:
                    times["dma_complete"].append(timestamp)
            if "TMEM_DMA_CMD_PERF |" in line:
                fields = dict(re.findall(r"(\w+)=([^,}]+)", line))
                for field, value in fields.items():
                    if value.isdigit():
                        fields[field] = int(value)
                commands.append(fields)
    # tb_vcs_xrtsim has a 10 ns period; %t prints in 1 ps precision.
    metrics = {"trace_failures": failures, "dma_commands": commands}
    for slot_record in slot_metrics.values():
        for key in ("request_to_response_cycles", "allocation_to_release_cycles"):
            values = slot_record[key]
            slot_record[key] = {"count": len(values), "min": min(values) if values else None,
                                "max": max(values) if values else None,
                                "mean": sum(values) / len(values) if values else None}
        final = slot_record.get("final_summary", {})
        slot_record["complete_and_balanced"] = bool(final) and (
            final.get("requests") == slot_record["allocation_events"]
            == final.get("responses") == slot_record["request_to_response_cycles"]["count"]
            == final.get("releases") == slot_record["allocation_to_release_cycles"]["count"]
        )
    metrics["response_slot_metrics"] = slot_metrics
    for key, values in times.items():
        metrics[key + "_count"] = len(values)
        metrics[key + "_span_cycles"] = (values[-1] - values[0]) / 10000 if values else None
    if times["dma_accept"] and times["dma_complete"]:
        metrics["dma_total_span_cycles"] = (times["dma_complete"][-1] - times["dma_accept"][0]) / 10000
    trailing_stores = []
    for command in reversed(dma_accepts):
        if command["op"].strip() != "0x2":
            break
        trailing_stores.append(command)
    metrics["final_store_count"] = len(trailing_stores)
    if trailing_stores:
        metrics["final_store_accept_span_cycles"] = (trailing_stores[0]["timestamp"] - trailing_stores[-1]["timestamp"]) / 10000
    return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--config", default="configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh",
                        help="Configuration path, relative to the build's source root")
    parser.add_argument("--configs-extra", default="", help="Explicit comparison-only extra defines")
    parser.add_argument("--case", choices=CASES, action="append")
    args = parser.parse_args()
    build = args.build.resolve()
    out = args.out.resolve()
    if not (build / "config.mk").exists():
        parser.error("The build must already be configured")
    if out.exists():
        parser.error("Use a new output directory to preserve existing evidence")
    out.mkdir(parents=True)
    config_match = re.search(r"^VORTEX_HOME\s*\?=\s*(.+)$", (build / "config.mk").read_text(), re.M)
    source = Path(config_match[1])
    config = source / args.config
    extra_configs = EXTRA_CONFIGS + " " + args.configs_extra
    spec = importlib.util.spec_from_file_location("verify_rtl", source / "tools/verify_rtl.py")
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    summary = {"build": str(build), "source": str(source), "config": str(config),
               "config_sha256": sha256(config), "extra_configs": extra_configs,
               "vendor_simlib": os.environ.get("SIMLIB_DIR"), "runs": []}
    shell = ('set -euo pipefail; source "$1"; export CONFIGS="$CONFIGS $2"; '
             'export PATH="/usr/bin:$PATH"; exec timeout "$3" ci/run_black.sh '
             'xrt-vcs-sim --app fpint_gemm_ffn_hw --args "$4" --debug 3')
    for name in args.case or CASES:
        for repeat in range(1, args.repeat + 1):
            prefix = out / f"{name}-{repeat}"
            started = time.time()
            with prefix.with_suffix(".wrapper.log").open("w") as wrapper:
                result = subprocess.run(["bash", "-c", shell, "measure-gemm", str(config), extra_configs,
                                         str(args.timeout), CASES[name]], cwd=build, stdout=wrapper,
                                        stderr=subprocess.STDOUT)
            record = {"case": name, "repeat": repeat, "args": CASES[name], "returncode": result.returncode,
                      "elapsed_seconds": round(time.time() - started, 1)}
            app_log = build / "run.log"
            app_text = app_log.read_text(errors="replace") if app_log.exists() else ""
            if app_log.exists():
                shutil.copy2(app_log, prefix.with_suffix(".app.log"))
            record["host_perf_cycles"] = [int(x) for x in re.findall(r"PERF:.*?cycles=(\d+)", app_text)]
            simv = build / "sim/xrtsim_vcs/simv"
            if simv.exists():
                record["simv_sha256"] = sha256(simv)
                record["simv_shared_objects_sha256"] = {
                    path.name: sha256(path)
                    for path in sorted(simv.with_name("simv.daidir").glob("*.so"))
                }
            app_dir = build / "tests/regression/fpint_gemm_ffn_hw"
            record["application_artifacts_sha256"] = {
                name: sha256(app_dir / name)
                for name in ("kernel.vxbin", "fpint_gemm_ffn_hw")
                if (app_dir / name).exists()
            }
            trace = build / "sim/xrtsim_vcs/simv.log"
            if trace.exists():
                record.update(trace_metrics(trace, verifier))
                with trace.open("rb") as src, gzip.open(prefix.with_suffix(".simv.log.gz"), "wb", compresslevel=1) as dst:
                    shutil.copyfileobj(src, dst)
            slot_evidence_complete = all(
                item["complete_and_balanced"]
                for item in record.get("response_slot_metrics", {}).values()
            )
            record["status"] = "pass" if (result.returncode == 0 and verifier.check_pass(app_text)
                                                and not record.get("trace_failures")
                                                and slot_evidence_complete) else "fail"
            summary["runs"].append(record)
            (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            print(json.dumps({k: v for k, v in record.items() if k != "dma_commands"}), flush=True)
            if record["status"] != "pass":
                return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
