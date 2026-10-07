"""Clone rev4 measurements and construct exact physical GEMM refresh suites."""
import csv
import dataclasses
import hashlib
import json
from pathlib import Path
import subprocess
import sys

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO))
from tools.latency_bench.candidate_map import resolve_candidate_map
from tools.latency_bench.suite import BenchCase, BenchDefaults, BenchSuite, suite_to_expanded_yaml
from tools.latency_bench.suite_io import write_suite_payload
from tools.latency_bench.yaml_io import safe_load, safe_dump
W = REPO / "analysis_workspace/latency_on_hw"
DOC = Path(__file__).resolve().parent
OLD = "th16_20261004_rev4_pipeline"
NEW = "th16_20261007_rev5_pipeline"
APP = "fpint_gemm_ffn_hw"

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    candidate = W / "candidate_fpga_bins.rev5.yaml"
    assert not candidate.exists(), candidate
    mapping = safe_load((W / "candidate_fpga_bins.rev4.yaml").read_text())
    mapping["candidates"]["C4"] = "improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_fix_pad"
    with candidate.open("w") as f:
        safe_dump(mapping, f, sort_keys=False)
    snapshot = resolve_candidate_map(candidate)
    baseline = {"source_tag": OLD, "tag": NEW, "app": APP,
                "candidate_map": str(candidate), "snapshot": snapshot, "models": {}}
    for model in ("llama2", "llama3"):
        src = W / f"outputs_{model}_main.{OLD}"
        dst = W / f"outputs_{model}_main.{NEW}"
        assert not dst.exists(), dst
        subprocess.run(["cp", "-a", "--reflink=auto", str(src), str(dst)], check=True)
        info = {"source": str(src), "output": str(dst), "raw_sha256": {},
                "board": json.loads((src / "model_fpga.json").read_text()), "stages": {}}
        for label in ("C1", "C3", "C4"):
            info["raw_sha256"][label] = sha(src / label / "raw_db.csv")
            assert sha(dst / label / "raw_db.csv") == info["raw_sha256"][label]
        rows = list(csv.DictReader((src / "C4/raw_db.csv").open()))
        target = [row for row in rows if row["app"] == APP]
        assert all(row["status"] == "pass" and row["measure_latency"] == row["measure_power"] == "1" for row in target)
        assert len({row["args"] for row in target}) == len(target)
        archives = {}
        grouped = {"prefill": [], "generation": []}
        for row in target:
            run = row["run_id"]
            if run not in archives:
                archives[run] = {c["exec_key"]: c for c in csv.DictReader((src / "C4/runs" / run / "cases.csv").open())}
            saved = archives[run][row["exec_key"]]
            case = BenchCase(case_id="refresh_" + row["exec_key"], app=APP, args=row["args"],
                model=saved["model"], kind="gemm", backend=saved["backend"], name=saved["name"],
                stage=saved["stage"], warmup=int(row["warmup"]), iterations=int(row["iterations"]),
                fpga_bin="C4", xclbin_sha256=snapshot["candidates"]["C4"]["xclbin_sha256"],
                source="rev4_physical_measurement", padded_args=row["padded_args"])
            grouped[case.stage].append(case)
        for stage, cases in grouped.items():
            suite = BenchSuite(name=f"{model}_{stage}_rev5_c4_gemm_refresh",
                defaults=BenchDefaults(warmup=0, iterations=1, fpga_bin="C4",
                    xrt_device_index=int(info["board"]["xrt_device_index"])), cases=cases, experiment=snapshot)
            path = DOC / f"{model}_{stage}.pkl"
            write_suite_payload(path, suite_to_expanded_yaml(suite))
            info["stages"][stage] = {"suite": str(path), "count": len(cases)}
        info["target_count"] = len(target)
        info["preserved_c4_count"] = len(rows) - len(target)
        baseline["models"][model] = info
        print(model, info["target_count"], info["stages"], flush=True)
    (DOC / "revision.json").write_text(json.dumps(baseline, indent=2) + "\n")

if __name__ == "__main__":
    main()
