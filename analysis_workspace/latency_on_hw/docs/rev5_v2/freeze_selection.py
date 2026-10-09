"""Freeze the QK/reorder selection before executing the selective workflow."""
import json
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO))
from tools.latency_bench.selective_rerun import selected_suite
from tools.latency_bench.suite import load_suite
from tools.latency_bench.suite_io import indexed_suites
from tools.latency_bench.kernel_variants import source_identity

DOC = Path(__file__).resolve().parent
W = DOC.parents[1]
FILTER = "(app=sgemm_tcu & name=attn_qkT) | backend=head_reorder"


def main():
    selection = {"filter": FILTER, "models": {}, "source_identities": {
        app: source_identity(REPO, app) for app in ("sgemm_tcu", "head_concat")}}
    for model, key in (("llama2", "llama2_7b"), ("llama3", "llama3_8b")):
        selected = {}
        for stage in ("prefill", "generation"):
            index = W / f"generated_suites/{key}_main_full.rev5_v2/{stage}_merged/index.yaml"
            paths = [path for label, path in indexed_suites(index) if label == "C1"]
            assert len(paths) == 1, paths
            suite = selected_suite(load_suite(paths[0], repo_root=REPO),
                W / f"outputs_{model}_main.rev5_v2/C1/raw_db.csv", (FILTER,), "C1", stage)
            cases = {c.exec_key: c for c in suite.cases if c.measurement_kind == "measured"}
            assert all((c.app == "sgemm_tcu" and c.name == "attn_qkT")
                       or (c.app == "head_concat" and c.backend == "head_reorder")
                       for c in cases.values())
            rows = [dict(exec_key=c.exec_key, app=c.app,
                         args=c.measurement_args or c.args, name=c.name,
                         stage=stage) for c in cases.values()]
            selected[stage] = {"suite": str(paths[0]), "physical_cases": rows,
                "qk": sum(c.app == "sgemm_tcu" for c in cases.values()),
                "reorder": sum(c.app == "head_concat" for c in cases.values())}
            print(model, stage, {k: selected[stage][k] for k in ("qk", "reorder")}, flush=True)
        selection["models"][model] = selected
    (DOC / "selection.json").write_text(json.dumps(selection, indent=2) + "\n")


if __name__ == "__main__":
    main()
