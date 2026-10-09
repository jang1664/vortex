# C2 Llama3 B1/S1024 connected decoder timing (2026-10-09)

Measured one real-size Llama3-8B decoder layer: H=4096, F=14336, Q=32,
KV=8, D=128, batch 1 and 1024 prefill tokens. All 32 QK/PV heads execute;
there is no head-count multiplication in postprocessing.

Image: `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3_axi_fix`.
FPGA: `0000:3d:00.1`, Slurm allocation 5781, one board for verification and
all timing/profile repetitions. Clock: 100 MHz. Runtime uses busy polling with
no fixed settle sleep. No kernel, RTL, or shared host changes were made for this
measurement; the previously built C2 decoder was used.

## Timing

The timer surrounds only `decoder.run(false,{})`. Uploads, intermediate downloads,
CPU checks, per-operation counter queries, setup and final-output download are
outside that interval. Three separate instrumented passes collect per-op cycles.
The graph contains 127 launches per complete layer.

| Wall repetition | Seconds |
|---|---:|
| 0 | 47.637037274 |
| 1 | 47.627929493 |
| 2 | 47.649164144 |
| Median | **47.637037274** |

Separate profile totals are 4,762,524,815; 4,767,295,628; and 4,767,859,911 cycles.
Their median is **47.672956280 s**. Wall median differs by -0.07535%; these are
separate passes, so the small negative difference is measurement/run variation,
not negative launch overhead.

## Correctness caveat

**Overall regression FAIL: same-input PV fails.** Timing was explicitly collected
in diagnostic mode as authorized. Final decoder output passes the existing gate
both before and after uninstrumented repetitions: relative L2 0.000898855,
max absolute error 0.01171875, 17,038/4,194,304 violating elements, no nonfinite
values, cosine 0.999999600. Final thresholds remain atol/rtol 0.005 and <=2%
violating elements; local thresholds remain 0.002.

PV/context is the sole failing same-input local check: relative L2 0.004242480,
violating fraction 0.072252035, max small-value absolute error 0.008453369.
All other same-input checks pass. Packed K/V weights, scales and zeros match
exactly. The selected DSP TCU image has the subnormal input-conversion defect
identified in [RESULTS.md](RESULTS.md); this run does not claim it is fixed.

## Profile breakdown

The table uses profile repetition 1, whose total is the median of the three
profile totals, so rows sum exactly to that pass. It excludes host downloads and
CPU validation.

| Group | Cycles | Seconds | Share |
|---|---:|---:|---:|
| ffn_hadamard | 1266760569 | 12.667606 | 26.57% |
| QK_TCU | 949224885 | 9.492249 | 19.91% |
| linear_gemm | 929377544 | 9.293775 | 19.49% |
| PV_TCU | 497781733 | 4.977817 | 10.44% |
| softmax | 318573456 | 3.185735 | 6.68% |
| head_reorder | 198580506 | 1.985805 | 4.17% |
| concat | 120366218 | 1.203662 | 2.52% |
| mlp_product | 97880578 | 0.978806 | 2.05% |
| silu | 80905764 | 0.809058 | 1.70% |
| q_hadamard | 56327738 | 0.563277 | 1.18% |
| KV_quant | 52753160 | 0.527532 | 1.11% |
| KV_dequant | 34205129 | 0.342051 | 0.72% |
| attention_residual | 27991692 | 0.279917 | 0.59% |
| output | 27991619 | 0.279916 | 0.59% |
| ffn_norm | 26270194 | 0.262702 | 0.55% |
| attention_norm | 26265067 | 0.262651 | 0.55% |
| rope | 25823634 | 0.258236 | 0.54% |
| KV_reorder | 16128431 | 0.161284 | 0.34% |
| k_hadamard | 14087711 | 0.140877 | 0.30% |

## Comparison limits

These connected-decoder adapters do not select every latency_on_hw default
variant. In particular:

- Head concat includes baseline `head_concat/kernel.cpp`; the independent default
  is `chunk16_packed`.
- Eladd lacks the independent default `ELADD_ROW_COALESCED_CURSOR` define.
- SiLU includes baseline `silu/kernel.cpp`; the independent default is
  `kernel.linear.cpp`.
- KV dequant includes the baseline implementation instead of the independent
  `groupwise_fp16` default. Figure accounting may also exclude dequantization.
- Explicit head/KV reorders are included in this connected graph.

Consequently the difference from the frozen rev5 aggregate must not be attributed
solely to launch overhead. Those measurements remain unchanged. The wall-versus-
cycle-sum comparison above is for the same connected implementation.

## Artifacts and reproduction

Build: `build_llama_decoder_c2_parallel_20261009`.
Artifact directory: `results/llama3_b1_s1024_timing_20261009` under that build.

- `run.sh` records the exact sequence and selects diagnostic timing only when
  packed KV checks are exact and any local failure is limited to PV/context.
- `session.txt` records allocation and timestamps; logs record image/config/BDF.
- `verify/` and `timing/` contain output checks, intermediates, and profile CSVs.
- `compare.log` and `timing_compare.log` retain the failed local PV check.
- `summary.json` and `summarize.py` contain the numeric summary and grouping.
- `sha256.json` fingerprints the actual executable, device binary, runtime,
  config, and fixture metadata used.

Run `run.sh` through an FPGA Slurm allocation from the configured build directory;
its `ci/run_black.sh hw --fpga-bin ... --run-only` invocations reuse that allocation.
