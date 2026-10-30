# No-prefill verification handoff

Two integrated node units and all seven fresh-artifact full-core cases PASS. No RTL/software/test edits were made by this verification agent. No owned verification process remains active.

## Core cycles

All runs use the configured XLEN64 build, the same C4 SRAM config, `ci/run_black.sh xrt-vcs-sim`, and identical `-DDISABLE_FSDB`. Lower cycles mean lower latency at the same clock. Original baseline is frozen commit12382c883; prior unified is the immediately preceding per-GEMM-prefill implementation.

| Case | Original | Prior unified + prefill | Corrected | vs original | vs prior unified |
|---|---:|---:|---:|---:|---:|
| FP32 M4/KV256 | 125,242 | 135,596 | 119,785 | -4.36% | -11.66% |
| FP16 M4/KV256 | 114,571 | 117,083 | 109,344 | -4.56% | -6.61% |
| Legacy M4/KV128 | 97,867 | 97,024 | 96,742 | -1.15% | -0.29% |
| FP32 tail M16/KV257 | 401,558 | 447,594 | 392,874 | -2.16% | -12.23% |
| FP32 causal M16/KV384 | 377,574 | 425,439 | 369,261 | -2.20% | -13.20% |

Exact core/attention values and both comparisons are in `cycle_comparison.json`; all seven cases, arguments, timestamps, numerical summaries and logs are in `results.json`.

## Functional coverage

- FP16 and FP32 node units ran through `tools/verify_rtl.py`, M=4 N=128 K=128, +SRAM_UNIFIED +NO_WAVE, with +SRAM_FP32 on the second run. Both passed on iteration1.
- Direct accepted-DMA monitors observed input/output command counts 0/1 for HBM input, 1/1 for LMEM input, and 0/1 for TMEM reuse. FP32-to-FP16 switch also observed0/1. No output-prefill command remained.
- Node output/padding comparisons passed after poisoning the LMEM destination on each job. One explicit OBUF initialization was reused across three same-format jobs; format switch explicitly reinitialized the new layout. Legacy before/after, copy-only roundtrip, invalid descriptors issuing no traffic, publication, delayed physical commits and FP32 values beyond65504 remained covered.
- All five paired attention workloads passed unchanged numerical tolerances. M4 multi-tile used7 commands: FP16 14,336 bytes and FP32 24,576 bytes. M16 tail/causal used10 commands and69,632 bytes. These full-core counts are software descriptor-derived; hardware direction/count proof comes from the independent node monitors.
- PV-overflow and QK-overflow M1/KV128 probes both passed exact output comparison (max_abs=0), each at62,274 core /56,062 attention cycles. PV reference partial was114,688.
- Existing serializer/early-return tests were not repeated because their logic and copy-only semantics did not change; no new claim of re-running those tests is made.

## Artifact audit

The first wrapper build silently reused the previous full-core simv: its hash matched the prior focused-app image and its mtime predated the changed sequencer. The first FP32 run and interrupted FP16 run are archived under `invalid_stale/` and excluded from every valid result. Unit runs were independent and valid.

The prior simv was moved safely to `invalid_stale/stale_simv`, then the same normal wrapper build was rerun. `build.log:1100` explicitly says `recompiling module VX_gemm_sram_io`. New simv mtime14:06:03 exceeds sequencer13:58:52, and SHA256 is `b8ea783f395a0c44cd1f2f835d4e000276bb1c8bd9574ef22fda76aeb9179eaa`. All seven accepted cases used this one image with run-only commands. Final source, simv and kernel hashes are unchanged; the CONFIGS string matches the original baseline exactly. Proof is in `setup.json`.

For future changed RTL under the current indirect-source dependency behavior, ensure a fresh full-core executable before relying on the wrapper build-only step; source hashes alone do not prove recompilation. No project Makefile/build-infrastructure fix was made here.

## Receipts and scope

- `verification/node_fp16_iter1.json` and `verification/node_fp32_iter1.json`, with archived compile/simulation logs.
- `STATUS.yaml` retains both accepted passes and the excluded stale-artifact attempt.
- `reference_results.json` freezes original and prior-unified results without overwriting their evidence.
- `run_case.sh`, `run_matrix.py`, and `collect_results.py` record the exact wrapper flow and comparison extraction.
- No synthesis, PnR, routed Fmax, FPGA hardware execution or commit was performed in this follow-up verification.
