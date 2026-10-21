# Rev8 C2 FPFP attention validation

Date: 2026-10-17. U55C, kernel 100 MHz, HBM 450 MHz. This change extends latency_on_hw generation and measurement; it does not modify RTL, GEMM kernels, or the connected C2 decoder.

## Selection and routing

`--c2-attn-backend auto|tcu|fpfp` is accepted by `workflow.py pipeline`, `make_case.sh`, `make_cases.sh`, and `tools.latency_bench generate-suites`. The low-level `tools/workload/gen_kernel_cfgs.py` accepts resolved `tcu|fpfp` values. Auto shares C1's config capability resolver; incompatible explicit choices fail before hardware execution.

`candidate_fpga_bins.rev8.yaml` C2 now selects:

```text
naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_fpfp_m8_n16_wload1_base_pnr_v3_qcol_pnr_spread
```

Hardware: FPINT naive 16x16 WLOAD4 QCOL plus FPFP naive 8x16 WLOAD1; no TCU. C1 stays on its existing FPFP-only alias.

| C2 work | Engine / app | Measurement source |
|---|---|---|
| Linear GEMM | Existing FPINT naive | C3, existing reuse policy |
| QKT / PV, FPFP option | `fpfp_gemm_ffn_hw_naive` | C2, even with FPFP C1 |
| QKT / PV, TCU option | `sgemm_tcu` | C1 if C1 is TCU; otherwise C2 |
| Standalone vectors / K transpose | Existing vector apps | C1 |

The shared FPFP conversion preserves C2 quantization/dequantization and FPINT linear kernels. Row-major FP16 weights require a K transpose after cache dequantization once per KV head. PV weights remain row-major. Execution M is preserved; decode sampling and measurement align K/N to 8/16. All four execution sources participate in run/refine/compose/plot when either candidate uses FPFP. Historical variant identifiers containing `sgemm_tcu` remain logical names; generated app/backend and snapshot select the actual arithmetic engine.

## Hardware functionality

Ran configured build `build_rev8_c2_fpfp` using `ci/run_black.sh hw --fpga-bin <new-C2-alias>`. FPFP inputs use deterministic random seeds 7/11/13/17/19; reference follows the existing FP32 tree/accumulation and final FP16 rounding. All six runs have zero numerical/bit mismatches and no NaN/Inf.

| Case | M | K | N | Cycles | Result |
|---|---:|---:|---:|---:|---|
| FPFP prefill QKT | 32 | 128 | 32 | 13,712 | PASS |
| FPFP prefill PV | 32 | 32 | 128 | 13,704 | PASS |
| FPFP decode QKT | 4 | 128 | 48 | 13,016 | PASS |
| FPFP decode PV | 4 | 40 | 128 | 12,377 | PASS |
| FPFP multi-tile | 256 | 256 | 256 | 164,944 | PASS |
| FPINT linear | 4 | 256 | 256 | 17,762 | PASS |

Existing TCU C2 alias `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3_qcol_fix_sub_norm` also passed `sgemm_tcu -m 32 -k 128 -n 32` in `build_rev8_c2_tcu` (63,186 cycles). These are functionality smoke measurements, not a controlled engine performance comparison.

## Generated workflow execution

`workflow.py pipeline --to generate` completed for Llama2-7B and Llama3-8B under tag `rev8_c2_fpfp_smoke`, B1, S32/KV32, three decode steps, capacity 64. Both C2 merged suites contain only FPFP attention, retain the C2 snapshot, and remain separate from C1 FPFP rows. Each model was then run through `workflow.py run`, filtered to execution source C2, with power disabled for the latency smoke. The three decode steps share aligned shapes and each operation is measured once.

| Model | Measured M/K/N | FPGA cycles | Status |
|---|---|---:|---|
| llama2 | `-m 32 -k 128 -n 32` | 13,717 | PASS |
| llama2 | `-m 32 -k 32 -n 128` | 13,884 | PASS |
| llama2 | `-m 1 -k 128 -n 48` | 12,843 | PASS |
| llama2 | `-m 1 -k 40 -n 128` | 12,420 | PASS |
| llama3 | `-m 32 -k 128 -n 32` | 13,788 | PASS |
| llama3 | `-m 32 -k 32 -n 128` | 13,858 | PASS |
| llama3 | `-m 4 -k 128 -n 48` | 12,829 | PASS |
| llama3 | `-m 4 -k 40 -n 128` | 12,472 | PASS |

A separate workflow power-loop smoke for C2 decode PV M4/K40/N128 also passed and recorded 7 power samples. It used a deliberately short 1–2 second target and a relaxed smoke-test sample minimum; this is a loop/sampler integration check, not a power characterization. See `build_rev8_c2_fpfp/workflow_power/C2/raw_db.csv`.

## Software validation

- C1/C2 backend tests: 8 PASS, including all four engine combinations, C2 source routing, FPINT preservation, K transpose, sampling, and incompatible config rejection.
- Targeted backend/candidate/generation/canonicalization/merge tests: 44 PASS in total (including the 8 backend tests above).
- Pipeline tests: 62 PASS, including C2 run/refine/compose wiring and model-session settings serialization.
- Legacy generator kernels exactly match HEAD in 64 model/variant/stage combinations with default TCU options.
- Broader tests retain three known stale test methods: one reuse-only routing test includes no_reuse suites (12 subtest failures), and two generator tests expect obsolete decode padding/kernel ordering. The two generator failures reproduce with the HEAD generator; the routing failure was already documented by the C1 integration. These are excluded from the targeted passing suite, not changed by this task.

## Usage

From `analysis_workspace/latency_on_hw`, outside Slurm:

```bash
python workflow.py pipeline --tag rev8_c2_fpfp_pipeline \
  --candidate-map candidate_fpga_bins.rev8.yaml \
  --c1-gemm-backend auto --c2-attn-backend auto \
  --suite-size full --models llama2,llama3 \
  --model-execution parallel --parallel-fallback serial
```

For TCU C2, use a TCU-capable C2 candidate map (e.g. rev7) and `--c2-attn-backend tcu`. Rev8's new C2 image has no TCU and intentionally rejects that override. Use a new experiment tag after changing image/backend; existing captured suites/results are not overwritten.

Full-size latency/power acquisition, refinement measurements and final plots were not run. Connected C2 decoder backend selection is outside this latency_on_hw change.
