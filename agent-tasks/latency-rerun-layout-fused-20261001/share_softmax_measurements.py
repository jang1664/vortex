"""Reuse identical softmax executions between the two model output roots."""
from pathlib import Path
from dataclasses import replace
import csv
import hashlib
import json
import shutil
import sys
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
from tools.latency_bench.selective_rerun import selected_suite
from tools.latency_bench.raw_db import _measurement_key_from_row, _write_raw_rows
from tools.latency_bench.runner import (RunOptions, strict_measurement_policy,
    build_execution_units, evaluate_measurement_coverage, MeasurementReuseState)
from tools.latency_bench.suite import load_suite
from tools.latency_bench.suite_io import indexed_suites
BASE=ROOT/"analysis_workspace/latency_on_hw"
TAG="th16_20260920_c4_slots16_v2r1"
VARIANTS=("softmax_layout_fused=rev2_shuffle_cursor",)

def load_rows(path):
    with path.open(newline="") as f:return list(csv.DictReader(f))

def share(source_model,target_model,dry_run=False):
    source=BASE/f"outputs_{source_model}_main.{TAG}/C4"
    target=BASE/f"outputs_{target_model}_main.{TAG}/C4"
    slug={"llama2":"llama2_7b","llama3":"llama3_8b"}[target_model]
    imported=[];metadata={};seen=set()
    source_rows={_measurement_key_from_row(row):row for row in load_rows(source/"raw_db.csv")}
    target_rows={_measurement_key_from_row(row):row for row in load_rows(target/"raw_db.csv")}
    for stage in ("prefill","generation"):
        index=BASE/f"generated_suites/{slug}_main_full.{TAG}/{stage}_merged/index.yaml"
        path=next(p for label,p in indexed_suites(index) if label=="C4")
        suite=load_suite(path,warmup_override=0,iterations_override=1)
        suite=selected_suite(suite,target/"raw_db.csv",("app=softmax_layout_fused",),"C4",stage)
        candidate=suite.experiment["candidates"]["C4"]
        # Every reused point must satisfy the destination's actual contract.
        options=RunOptions(ROOT/f"build_latency_{target_model}",Path(candidate["bin_dir"]),target,
            suite.defaults.platform,fpga_bin_label="C4",configs=Path(candidate["config"]),
            application_source_identity="shared-physical-execution",kernel_variants=VARIANTS,
            strict_measurement_reuse=True,adopt_legacy=False,measure_latency=True,measure_power=True,
            power_auto_duration=False,power_min_interval=0.01,power_latency_interval=0.1,
            power_idle_stability_policy=BASE/"idle_stability_policy.json",
            power_kernel_iterations=1,power_kernel_iterations_auto=True,power_target_sec=10.0)
        policy=strict_measurement_policy(suite,options,xclbin_sha256=candidate["xclbin_sha256"])
        units=build_execution_units(suite,target/"shared-inspection")
        own={e.exec_key for e in evaluate_measurement_coverage(target/"raw_db.csv",units,policy).evidence
             if e.state is MeasurementReuseState.REUSE}
        reusable={e.exec_key:e for e in evaluate_measurement_coverage(source/"raw_db.csv",units,policy).evidence
                  if e.state is MeasurementReuseState.REUSE and e.exec_key not in own}
        for case in suite.cases:
            if case.exec_key not in reusable or case.measurement_kind!="measured":continue
            key=("C4",candidate["xclbin_sha256"],case.app)
            # Match using the same canonical physical key as row replacement.
            from tools.latency_bench.raw_db import _normalize_args
            key=(*key,_normalize_args(case.measurement_args or case.args))
            if key in seen:continue
            seen.add(key)
            row=source_rows[key];run_id=row["run_id"]
            if dry_run:
                imported.append(row)
                continue
            src_run=source/"runs"/run_id;dst_run=target/"runs"/run_id
            if not dst_run.exists():
                shutil.copytree(src_run,dst_run)
                for artifact in dst_run.rglob("*"):
                    if artifact.is_file() and artifact.suffix in (".json",".csv",".yaml"):
                        value=artifact.read_text()
                        if str(src_run) in value:artifact.write_text(value.replace(str(src_run),str(dst_run)))
                manifest=dst_run/"manifest.json";value=json.loads(manifest.read_text())
                value["measurement_import_origin"]={"model":source_model,"manifest":str(src_run/"manifest.json"),
                    "manifest_sha256":hashlib.sha256((src_run/"manifest.json").read_bytes()).hexdigest(),
                    "reason":"identical physical execution, verified with destination strict reuse policy"}
                manifest.write_text(json.dumps(value,indent=2)+"\n")
            metadata[run_id]=json.loads((dst_run/"kernel_variants.json").read_text())["apps"]
            imported.append({k:v.replace(str(src_run),str(dst_run)) for k,v in row.items()})
    if imported and not dry_run:
        _write_raw_rows(imported,target/"raw_db.csv",mode="replace",run_id="shared-physical-execution")
        path=target/"kernel_variants.json";value=json.loads(path.read_text());value["runs"].update(metadata)
        path.write_text(json.dumps(value,indent=2,sort_keys=True)+"\n")
    return dict(source=source_model,target=target_model,imported=len(imported),
                exec_keys=[r["exec_key"] for r in imported],run_ids=sorted(metadata))

def main():
    dry_run="--dry-run" in sys.argv
    results=[share("llama2","llama3",dry_run),share("llama3","llama2",dry_run)]
    if dry_run:
        print([{k:v for k,v in r.items() if k not in ("exec_keys","run_ids")} for r in results])
        return
    path=Path(__file__).with_name("shared_measurements.json")
    previous=json.loads(path.read_text()) if path.exists() else []
    path.write_text(json.dumps(previous+results,indent=2)+"\n")
    print([{k:v for k,v in r.items() if k not in ("exec_keys","run_ids")} for r in results])
if __name__=="__main__":main()
