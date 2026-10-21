# Rev8 C1 FPFP integration validation

Date: 2026-10-15. Hardware: U55C, 100 MHz. No RTL or FPGA image was changed for this integration.


The later [C2 FPFP integration](../rev8_c2_fpfp/VALIDATION.md) updates rev8 C2; the mappings below describe the original C1-only validation.

## Candidate and execution routing

`candidate_fpga_bins.rev8.yaml` copies rev7 and changes only C1 to `fpfp_th16_m8_n16_wload1_all_bram_acc`. Its config is `configs/fpfp_th16_m16_n16_wload4_all_bram_acc.sh`; despite the historical filename, the physical FPFP geometry is **8x16, WLOAD1**.

| Logical workload | Linear GEMM | QKT / PV | Standalone vector sources |
|---|---|---|---|
| C1, TCU option | C1 TCU | C1 TCU | C1 |
| C1, FPFP option | C1 FPFP | C1 FPFP | C1 |
| C2 with FPFP C1 | C3 FPINT naive | **C2 TCU** | C1 |
| C3 | C3 FPINT naive | C3 FPINT naive | C1 |
| C4 fused | C4 improve | C4 improve | C4 fused |

C2 must not reuse FPFP C1 attention timings. Its TCU rows now have their own C2 raw DB and run/refine tasks. Compose/plot require all four physical execution sources for FPFP C1; old TCU experiments retain three sources.

## Connected decoder functionality

The existing `llama_decoder_C1` app selects the engine at build time from config (`C1_GEMM_BACKEND=auto|tcu|fpfp`). Its CLI backend option checks compatibility. Fixtures have a backend field and the correct physical FP16 weight orientation. FPFP adds the existing head-transpose kernel once per KV head for K; PV and linear weights are row-major. The CPU logical reference and quantization policy remain unchanged.

One real-size Llama decoder layer, deterministic random weights/activations, B1. Prefill S32. Decode consumes a 32-token CPU prefix, produces one token (valid KV=33), and allocates capacity 64. All heads execute.

| Engine | Model | Stage | Final output | Max absolute error | Relative L2 (%) | Violations / elements |
|---|---|---|---|---:|---:|---:|
| FPFP | llama2 | prefill | PASS | 0.01269531 | 0.103511 | 1467 / 131072 |
| FPFP | llama2 | decode | PASS | 0.00195312 | 0.052677 | 0 / 4096 |
| FPFP | llama3 | prefill | PASS | 0.00390625 | 0.041089 | 1 / 131072 |
| FPFP | llama3 | decode | PASS | 0.00195312 | 0.047983 | 0 / 4096 |
| TCU | llama3 | prefill | PASS | 0.00390625 | 0.041089 | 1 / 131072 |
| TCU | llama3 | decode | PASS | 0.00195312 | 0.047983 | 0 / 4096 |

The established final-output gate was kept unchanged: no nonfinite values, violation fraction ≤2%, relative L2 ≤1%, cosine ≥0.999. The per-element check uses absolute 0.005 for reference magnitudes below 0.25 and relative 0.005 otherwise. Llama2 prefill has 1.119% violating elements, so PASS does **not** mean every element meets the threshold. No tolerance was relaxed here.

Raw verification JSON and op logs: `build_rev8_c1_fpfp/results/{llama2,llama3}_{prefill,decode}` and `build_rev8_c1_tcu/results/llama3_{prefill,decode}`. The `run_validation.sh` wrapper also passed the FPFP Llama3 decode fixture using automatic backend selection.

## Standalone benchmark and workflow checks

- Added the FPFP bench harness by reusing the existing naive benchmark with compile-time FP16 operand setup, FP16 scratch sizes, and no scale/zero-point device buffers. Existing FPINT behavior stays unchanged.
- Hardware benchmark M4/K256/N256 completed; the device-side 1,000-GEMM power loop completed and its sampler shut down normally. This is a power-path smoke test, not an accurate power characterization (the run is intentionally short).
- `ci/test_llm_regression.py` detects FPFP C1 from its config. Static preflight and all three selected functionality cases passed: M8/K32/N16 (11,673 cycles), M16/K64/N32 (12,438), M17/K64/N33 (12,617). Gate reports **PARTIAL_PASS** because only FPFP GEMM was selected, not every vector/fused pair.
- `workflow.py pipeline --to generate` completed for both models, tag `rev8_c1_fpfp_smoke`, S32 and three decode steps. Both execution indexes include C1/C2/C3/C4. C1 has FPFP GEMMs and no TCU app; C2 contains TCU attention.
- `workflow.py run` executed the generated C1 decode PV case: logical K33/34/35 share physical **M4/K40/N128**; raw DB status PASS, **12,558 FPGA cycles**. Alias, image SHA and 100 MHz period are recorded in `build_rev8_c1_fpfp/workflow_run_verified/C1/raw_db.csv`.
- Decode sampling uses FPFP K8/N16 boundaries, preserves M, and includes K transpose in interpolation/refinement groups. Pipeline run/refine/compose/plot task wiring includes C2.
- 61 pipeline tests, 33 candidate/backend/canonicalization tests, and 12 regression-gate tests passed (106 total). A direct comparison with the pre-change generator found identical legacy kernels in 64 model/variant/stage combinations.
- Some broader pre-existing tests have stale expectations: the reuse-routing test includes `no_reuse` suites, and older workload tests expect former decode padding/call counts. Re-running those checks with the HEAD generator reproduces the same failures; they were not changed as part of this feature. See `build_rev8_c1_fpfp/legacy_test_baseline.log`.

Full-size latency/power acquisition and final plots were **not** run. Validation covers small hardware workloads plus generation and downstream task wiring, not a completed full benchmark campaign.

## Usage

From `analysis_workspace/latency_on_hw`, outside a Slurm allocation:

```bash
python workflow.py pipeline --tag rev8_pipeline \
  --candidate-map candidate_fpga_bins.rev8.yaml --c1-gemm-backend auto \
  --suite-size full --models llama2,llama3 \
  --model-execution parallel --parallel-fallback serial
```

Use rev7 with `--c1-gemm-backend tcu` for the existing TCU C1. Incompatible image/backend choices fail before hardware execution. The current workflow FPFP alignment policy describes the rev8 8x16 image; another physical geometry needs a matching sampling/canonicalization policy.

Full-run output directories for this example tag:

- `generated_suites/{llama2_7b,llama3_8b}_main_full.rev8_pipeline/`
- `outputs_{llama2,llama3}_main.rev8_pipeline/{C1,C2,C3,C4}/raw_db.csv`
- `composed_results.rev8_pipeline/`
- `figure_prepare.rev8_pipeline/`
- `figure_output.rev8_pipeline/`

Tested Python environments: `~/.conda/envs/vortex/bin/python` for the workflow/tests; `~/.conda/envs/py310/bin/python` with sibling TVM Python/apps and its compiled tvm-ffi extension for CPU fixtures. Activate the workflow environment so subprocess `python3` has pandas/YAML available.
