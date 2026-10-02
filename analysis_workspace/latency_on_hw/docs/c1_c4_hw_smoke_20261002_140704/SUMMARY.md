# C1-C4 FPGA hardware smoke test

All 35 kernel executions completed on real U55C hardware: **25 PASS, 10 numerical verification FAIL**. There were no timeouts or observed hangs. These are functional smoke checks, with one representative shape per app, not a latency benchmark or shape sweep.

## Hardware and commands

- Candidate aliases come from the saved `candidate_fpga_bins.yaml`, copied from `analysis_workspace/latency_on_hw/candidate_fpga_bins.yaml`.
- All invocations run sequentially from the configured repository `build/` directory using `ci/run_black.sh hw --fpga-bin ALIAS --app APP --args ...`. There is no `build/run_black.sh`; the existing wrapper is `build/ci/run_black.sh`.
- The wrapper sources each alias config and allocates a U55C via Slurm. No extra hardware compile-time defines, benchmark mode or verification-disabling options were added.
- The logs identify XRT device index 0, BDF `0000:2a:00.1`, for all runs.
- `run_smoke.py`, `experiment.json`, `environment.json`, frozen alias/candidate maps, per-candidate config snapshots, and per-case `command.sh`, `run.log`, `result.json` retain the commands and evidence.

| Candidate | FPGA alias | Config |
|---|---|---|
| C1 | `tcu_th16_c1_v2_rev2` | `configs/tcu_th16_c1_v2.sh` |
| C2 | `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v2` | `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v2.sh` |
| C3 | `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2` | `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh` |
| C4 | `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2` | `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2.sh` |

## Verification matrix

`—` means not selected for this architecture. C1 has no dedicated FPINT accelerator; its `gemm_fpint` app uses software INT4 dequantization and TCU matrix multiplication. C2/C3 use the naive accelerator, and C4 uses improve. C3/C4 have no TCU.

| App | C1 | C2 | C3 | C4 |
|---|---|---|---|---|
| `rmsnorm` | [FAIL](C1/rmsnorm/run.log) | [FAIL](C2/rmsnorm/run.log) | [FAIL](C3/rmsnorm/run.log) | [FAIL](C4/rmsnorm/run.log) |
| `rope` | [PASS](C1/rope/run.log) | [PASS](C2/rope/run.log) | [PASS](C3/rope/run.log) | [PASS](C4/rope/run.log) |
| `softmax` | [PASS](C1/softmax/run.log) | [PASS](C2/softmax/run.log) | [PASS](C3/softmax/run.log) | [PASS](C4/softmax/run.log) |
| `silu` | [PASS](C1/silu/run.log) | [PASS](C2/silu/run.log) | [PASS](C3/silu/run.log) | [PASS](C4/silu/run.log) |
| `eladd` | [PASS](C1/eladd/run.log) | [PASS](C2/eladd/run.log) | [PASS](C3/eladd/run.log) | [PASS](C4/eladd/run.log) |
| `elmul` | [FAIL](C1/elmul/run.log) | [FAIL](C2/elmul/run.log) | [FAIL](C3/elmul/run.log) | [FAIL](C4/elmul/run.log) |
| `kv_cache_quant_w4a16` | [PASS](C1/kv_cache_quant_w4a16/run.log) | [PASS](C2/kv_cache_quant_w4a16/run.log) | [PASS](C3/kv_cache_quant_w4a16/run.log) | [PASS](C4/kv_cache_quant_w4a16/run.log) |
| `sgemm_tcu` | [FAIL](C1/sgemm_tcu/run.log) | [FAIL](C2/sgemm_tcu/run.log) | — | — |
| `gemm_fpint` | [PASS](C1/gemm_fpint/run.log) | — | — | — |
| `fpint_gemm_ffn_hw_naive` | — | [PASS](C2/fpint_gemm_ffn_hw_naive/run.log) | [PASS](C3/fpint_gemm_ffn_hw_naive/run.log) | — |
| `fpint_gemm_ffn_hw` | — | — | — | [PASS](C4/fpint_gemm_ffn_hw/run.log) |
| `fpint_gemm_eladd_fused_hw` | — | — | — | [PASS](C4/fpint_gemm_eladd_fused_hw/run.log) |

## One representative workload per app

| App | Args |
|---|---|
| `rmsnorm` | `-batch 1 -seq 32 -hidden 128` |
| `rope` | `-batch 1 -seq 32 -heads 2 -headdim 64 -maxseq 64 -offset 0` |
| `softmax` | `-batch 1 -heads 1 -seqq 128 -seqk 128 -seqk-stride 128 -mask 1` |
| `silu` | `-n 4096` |
| `eladd` | `-n 4096` |
| `elmul` | `-n 4096` |
| `kv_cache_quant_w4a16` | `-k 128 -n 128 -q 32 -d 1 -t 0 --quant-mode spinquant_signed_symmetric` |
| `sgemm_tcu` | `-m 64 -n 64 -k 128` |
| `gemm_fpint` | `-m 64 -n 64 -k 128 -g 32` |
| `fpint_gemm_ffn_hw_naive` | `-m 128 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1` |
| `fpint_gemm_ffn_hw` | `-m 128 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1` |
| `fpint_gemm_eladd_fused_hw` | `-m 128 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1` |

Actual variants: RMSNorm `adaptive_m_rows`, RoPE `task_chunk16`, softmax `rev2_shuffle_grouped`, SiLU `linear`, eladd `row_coalesced_cursor`, KV quantization `groupwise_fp16`, TCU GEMM `b_colmajor`. Elmul uses its existing `kernel.cpp`; the recorded `ELMUL_VARIANT` environment value is unused by its Makefile. Quantization tests signed symmetric V quantization (QDIR=1). GEMM accelerator tests use M=128, K=N=256, QBLK=32, WTRANS=0, QDIR=0, REPS=1.

## Numerical failures

All eight RMSNorm/elmul failures have the same error positions and values across candidates. They occur in FP16 subnormal magnitudes, with signed zero returned by the FPGA. This is consistent with flush-to-zero behavior in the hardware conversion path. It is not a proof of every intermediate value or an exhaustive characterization of that path.

| App | Candidates | Output index | CPU reference | FPGA output |
|---|---|---:|---:|---:|
| RMSNorm | C1-C4 | 1403 | 0.000027 | 0 |
| RMSNorm | C1-C4 | 1961 | 0.000060 | 0 |
| Elmul | C1-C4 | 1302 | 0.000043 | 0 |
| Elmul | C1-C4 | 2769 | -0.000009 | -0 |

`tests/regression/vector_common/fp16.h` implements subnormal-preserving conversions for the CPU reference. With Zfh enabled, the kernel instead uses `fcvt.s.h` / `fcvt.h.s`; the Vivado DSP conversion path in `hw/rtl/fpu/VX_fpu_f2f.sv` uses `xil_f16_to_f32` / `xil_f32_to_f16`. RMSNorm writes `float_to_fp16(val * rms_norm * gamma)` and elmul writes `float_to_fp16(a * b)`. Both reference checkers reject these observed differences.

The two `sgemm_tcu` failures also match exactly on C1/C2: output index 1969, reference **29.671875**, FPGA **29.687500**, difference **0.015625**, one FP16 ULP at this magnitude. Its current checker uses absolute tolerance `FP_COMPARE_THRESHOLD=0.001`, so this is reported as one failure out of 4,096 outputs. No tolerance or input was changed to turn a failing result into PASS. The separate C1 `gemm_fpint` path passes its existing check.

## Recorded core cycles

These single-launch values include job setup and completion polling. They are supporting evidence of completed execution, not controlled latency comparisons.

| Candidate | App | Cycles | Instructions | Verification |
|---|---|---:|---:|---|
| C1 | `rmsnorm` | 132,215 | 210,597 | FAIL |
| C1 | `rope` | 52,614 | 101,479 | PASS |
| C1 | `softmax` | 563,984 | 1,294,112 | PASS |
| C1 | `silu` | 51,281 | 88,930 | PASS |
| C1 | `eladd` | 104,771 | 95,794 | PASS |
| C1 | `elmul` | 61,450 | 97,506 | FAIL |
| C1 | `kv_cache_quant_w4a16` | 298,462 | 1,078,114 | PASS |
| C1 | `sgemm_tcu` | 153,700 | 514,419 | FAIL |
| C1 | `gemm_fpint` | 134,846 | 401,637 | PASS |
| C2 | `rmsnorm` | 133,004 | 210,597 | FAIL |
| C2 | `rope` | 53,111 | 101,479 | PASS |
| C2 | `softmax` | 562,072 | 1,294,112 | PASS |
| C2 | `silu` | 51,404 | 88,930 | PASS |
| C2 | `eladd` | 107,382 | 95,794 | PASS |
| C2 | `elmul` | 59,676 | 97,506 | FAIL |
| C2 | `kv_cache_quant_w4a16` | 294,542 | 1,078,114 | PASS |
| C2 | `sgemm_tcu` | 155,861 | 514,419 | FAIL |
| C2 | `fpint_gemm_ffn_hw_naive` | 52,110 | 9,689 | PASS |
| C3 | `rmsnorm` | 133,753 | 210,597 | FAIL |
| C3 | `rope` | 52,706 | 101,479 | PASS |
| C3 | `softmax` | 556,791 | 1,294,112 | PASS |
| C3 | `silu` | 50,836 | 88,930 | PASS |
| C3 | `eladd` | 110,080 | 95,794 | PASS |
| C3 | `elmul` | 59,801 | 97,506 | FAIL |
| C3 | `kv_cache_quant_w4a16` | 304,980 | 1,078,114 | PASS |
| C3 | `fpint_gemm_ffn_hw_naive` | 52,129 | 9,689 | PASS |
| C4 | `rmsnorm` | 132,141 | 210,597 | FAIL |
| C4 | `rope` | 52,894 | 101,479 | PASS |
| C4 | `softmax` | 552,731 | 1,290,016 | PASS |
| C4 | `silu` | 51,714 | 88,930 | PASS |
| C4 | `eladd` | 108,914 | 95,794 | PASS |
| C4 | `elmul` | 59,807 | 97,506 | FAIL |
| C4 | `kv_cache_quant_w4a16` | 293,720 | 1,078,114 | PASS |
| C4 | `fpint_gemm_ffn_hw` | 51,113 | 9,619 | PASS |
| C4 | `fpint_gemm_eladd_fused_hw` | 743,986 | 2,348,589 | PASS |

## Scope

The test run changed only generated build products and experiment artifacts. Functional RTL, kernel implementations and numerical tolerances were not edited. FAIL rows remain numerical failures; successful kernel completion does not imply their output passed verification. Each selected case has a zero/nonzero exit status and an explicit host PASS/FAIL message retained in its log. The final build app/runtime config is C4, as it was tested last.
