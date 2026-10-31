# FlashAttention versus separate QK + softmax + PV

Current SRAM FlashAttention is slower in all three measured workloads. All numerical checks passed.

## Method

- Llama3-8B, batch 1, complete attention across all heads. Same fixtures, same current unified-MMIO FPGA image and config, same decoder executable; only `--attention-backend` changes.
- Image: `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build/hw/syn/xilinx/xrt/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_20261030_unified_mmio_r1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin`; SHA256 `c330b5270631894e5462168aee7281e0d38bcfa1914cd5223d498b2977f239ff`.
- Image clock: 100 MHz. Reported milliseconds are core cycles / 100,000; they exclude host launch/wait time. They are attention-only, not whole-decoder latency.
- Existing legacy path dispatches QK, softmax and PV as separate kernels (batched heads per GEMM phase). Baseline is the sum of their three per-operation median core-cycle counts.
- FlashAttention is the complete `attention` operation including input adapters, initialization, GEMM, SRAM copies, SIMD and final output. No diagnostic timing or early-stop shortcut.
- Three measured profile passes per backend after warmup; wall timing uses separate passes and is not mixed into these comparisons.
- Verify runs passed full CPU intermediate/final-output checks. Cross-backend checks passed with identical Q and packed K/V inputs; timing runs also passed output gates.
- Scope is three selected cases, not the full nine-case functionality matrix or a large-sequence scaling study.

## Attention latency

| Workload | Separate QK + softmax + PV (ms) | Flash FP16 (ms) | FP16 slowdown | Flash FP32 (ms) | FP32 slowdown |
|---|---:|---:|---:|---:|---:|
| Decode: 1 query, KV=17, capacity=32 | 2.2921 | 17.0681 | 7.45x | 17.6188 | 7.69x |
| Decode: 1 query, KV=129, capacity=256 | 2.9461 | 12.8789 | 4.37x | 13.6909 | 4.65x |
| Prefill: 128 queries, KV=128 | 148.3712 | 534.5077 | 3.60x | 566.7470 | 3.82x |

## Separate operation medians (cycles)

| Workload | QK | Softmax | PV | Sum |
|---|---:|---:|---:|---:|
| Decode: 1 query, KV=17, capacity=32 | 47095 | 132092 | 50023 | 229210 |
| Decode: 1 query, KV=129, capacity=256 | 54985 | 182116 | 57514 | 294615 |
| Prefill: 128 queries, KV=128 | 526798 | 13774639 | 535687 | 14837124 |

## Resident phase medians (cycles)

`simd` includes initialization, online softmax, partial accumulation/rescaling and final normalization/output. `gemm_wait` includes input loads, internal SRAM DMA and polling; `sram_copy` covers one-time OBUF initialization. Individual phase medians need not sum exactly to the operation median.

| Workload | Mode | Whole attention | Shared-kernel total | SIMD | GEMM wait incl. DMA | OBUF init |
|---|---|---:|---:|---:|---:|---:|
| Decode: 1 query, KV=17, capacity=32 | resident | 1706815 | 687701 | 503075 | 84041 | 28362 |
| Decode: 1 query, KV=17, capacity=32 | resident-fp32 | 1761881 | 742332 | 501581 | 118361 | 50706 |
| Decode: 1 query, KV=129, capacity=256 | resident | 1287887 | 1246274 | 932132 | 166383 | 28362 |
| Decode: 1 query, KV=129, capacity=256 | resident-fp32 | 1369090 | 1326879 | 921724 | 235307 | 50706 |
| Prefill: 128 queries, KV=128 | resident | 53450765 | 53315618 | 47278757 | 4286902 | 1463389 |
| Prefill: 128 queries, KV=128 | resident-fp32 | 56674703 | 56536858 | 46702581 | 6646813 | 2902773 |

## Interpretation

- SIMD work is a substantial measured cost. Current flash scheduling executes GEMM, DMA and SIMD sequentially. SRAM residency by itself does not establish a latency improvement.
- Capacity=32 requires K/V padding/repacking to the fixed 128-key tile in `prepare_attention_inputs()`. The difference between whole-operation and shared-kernel timing also includes dispatch/wrapper overhead; it is not an isolated padding timer.
- Capacity=256 uses direct stored tiles, yet remains slower; input padding alone does not explain the result.
- No new RTL, kernel optimization, or timing exception was introduced for this comparison. The original config and numerical thresholds were retained.

Raw evidence: `matrix.json`, each case’s `verify/` and `timing/` directories, and `logs/`. The launcher is [run_comparison.sh](../20261031_unified_mmio_r1/run_comparison.sh). `comparison.json` retains median values and all three cycle samples.
