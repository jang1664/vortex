"""Apply remeasured QK/reorder/decode KV quant to documented Rev5 totals."""
import json
import sys
from dataclasses import replace
from pathlib import Path

import pandas as pd
import yaml

DOC = Path(__file__).resolve().parent
REPO = DOC.parents[3]
sys.path.insert(0, str(REPO))
from tools.latency_bench.compose import ComposeOptions, compose_latency
from tools.latency_bench.suite import load_suite

WORKSPACE = DOC.parents[1]
REFERENCE = WORKSPACE / "docs/whole_decoder_vs_aggregate"


def main():
    prefill = json.loads((REFERENCE / "C1_C3_B1_S1024_MATCHED_comparison.json").read_text())
    c4 = json.loads((REFERENCE / "C4_B1_S1024_VS_REV5_comparison.json").read_text())
    prefill["C4"] = {"adjusted_wall_s": c4["wall_seconds"],
                     "historical_layer_s": c4["historical_layer_s"]}
    decode = json.loads((REFERENCE / "C1_C4_DECODE_GROUPED_VS_REV5_comparison.json").read_text())
    old_prefill = pd.read_csv(REFERENCE / "rev5_llama3_b1_s1024_rows.csv")
    old_decode = pd.read_csv(REFERENCE / "rev5_decode_b1_p1024_first_step_rows.csv")
    suites = WORKSPACE / "generated_suites/llama3_8b_main_full.rev5_v2"
    baseline = json.loads((DOC / "baseline.json").read_text())["models"]["llama3"]
    frames, summary = [], []
    for stage in ("prefill", "generation"):
        for candidate in ("C1", "C2", "C3", "C4"):
            index = suites / f'{candidate if candidate != "C4" else "C4_fused"}_{stage}/index.yaml'
            entries = yaml.safe_load(index.read_text())["generated"]
            selected = []
            for entry in entries:
                path = index.parent / Path(entry["suite"]).name
                suite = load_suite(path, repo_root=REPO, warmup_override=0, iterations_override=1)
                cases = [case for case in suite.cases if case.batch == 1
                         and (case.backend == "head_reorder"
                              or (case.app == "sgemm_tcu" and case.name == "attn_qkT")
                              or (stage == "generation" and candidate == "C4"
                                  and case.app == "kv_cache_quant_layout_fused_w4a16"))
                         and ((stage == "prefill" and case.prefill_seq_len == 1024)
                              or (stage == "generation" and case.gen_kv_len == 1024
                                  and case.output_token_index == 1))]
                if cases:
                    selected.append(replace(suite, cases=cases))
            totals = {}
            new_kv_quant = 0.0
            for revision, root_key in (("rev5", "source"), ("rev5_v2", "output")):
                raw = tuple(Path(baseline[root_key]) / label / "raw_db.csv"
                            for label in ("C1", "C3", "C4"))
                parts = []
                for suite in selected:
                    cases = [case for case in suite.cases
                             if revision == "rev5_v2" or (
                                 case.backend != "head_reorder"
                                 and case.app != "kv_cache_quant_layout_fused_w4a16")]
                    if not cases:
                        continue
                    frame = compose_latency(replace(suite, cases=cases), ComposeOptions(
                        raw_dbs=raw, out=DOC, metric="fpga_cycle_latency",
                        select="latest", missing="error"))
                    assert frame["compose_status"].eq("pass").all()
                    frame["revision"] = revision
                    frame["candidate"] = candidate
                    frame["layer_seconds"] = frame["fpga_cycle_latency"] * frame["calls_per_forward"] / 32 / 1e6
                    parts.append(frame)
                if not parts:
                    totals[revision] = 0.0
                    if revision == "rev5_v2":
                        reorder = 0.0
                    continue
                result = pd.concat(parts, ignore_index=True)
                assert not result["case_id"].duplicated().any()
                frames.append(result)
                totals[revision] = float(result["layer_seconds"].sum())
                if revision == "rev5_v2":
                    reorder = float(result.loc[result["backend"].eq("head_reorder"), "layer_seconds"].sum())
                    quant = result.loc[result["app"].eq("kv_cache_quant_layout_fused_w4a16")]
                    if not quant.empty:
                        assert len(quant) == 2  # One K append and one V append, each weighted by all KV heads.
                        assert quant["measurement_args"].str.contains("--source-total-k 8", regex=False).all()
                        new_kv_quant = float(quant["layer_seconds"].sum())
            reference = prefill[candidate] if stage == "prefill" else decode[candidate]
            measured = reference["adjusted_wall_s" if stage == "prefill" else "measured_default_s"]
            original = reference["historical_layer_s" if stage == "prefill" else "rev5_first_step_s"]
            historical_rows = old_prefill if stage == "prefill" else old_decode
            historical_qk = historical_rows.loc[
                historical_rows["candidate"].eq(candidate)
                & historical_rows["app"].eq("sgemm_tcu")
                & historical_rows["op"].eq("attn_qkT")]
            column = "layer_latency_us" if stage == "prefill" else "layer_latency_s"
            historical_qk_s = float(historical_qk[column].sum()) / (1e6 if stage == "prefill" else 1)
            assert abs(totals["rev5"] - historical_qk_s) < 1e-8
            old_kv_quant = 0.0
            if stage == "generation" and candidate == "C4":
                old_quant = historical_rows.loc[
                    historical_rows["candidate"].eq(candidate)
                    & historical_rows["app"].eq("kv_cache_quant_layout_fused_w4a16")]
                assert len(old_quant) == 2
                old_kv_quant = float(old_quant["layer_latency_s"].sum())
            kv_quant_delta = new_kv_quant - old_kv_quant
            qk_delta = totals["rev5_v2"] - totals["rev5"] - reorder - new_kv_quant
            corrected = original + reorder + qk_delta + kv_quant_delta
            row = dict(stage=stage, candidate=candidate, measured_s=measured,
                       rev5_s=original, rev5_v2_s=corrected,
                       added_reorder_s=reorder,
                       qk_delta_s=qk_delta,
                       old_kv_quant_s=old_kv_quant, new_kv_quant_s=new_kv_quant,
                       kv_quant_delta_s=kv_quant_delta,
                       rev5_error_percent=100 * (original / measured - 1),
                       rev5_v2_error_percent=100 * (corrected / measured - 1),
                       absolute_error_reduction_pp=100 * (abs(original / measured - 1)
                                                         - abs(corrected / measured - 1)))
            summary.append(row)
            print(json.dumps(row), flush=True)
    pd.concat(frames, ignore_index=True).to_csv(DOC / "decoder_comparison_rows.csv", index=False)
    (DOC / "decoder_comparison.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
