# C1–C3 decoder versus latency_on_hw rev5: B1/S1024

2026-10-09. Llama3-8B, one complete decoder layer, batch 1, prefill 1024.
Hidden 4096, FFN 14336, 32 query heads, 8 KV heads, head dimension 128; all heads execute.
Inputs and weights are deterministic random. Embedding and LM head are excluded.

## Measured latency

| Candidate | Rev5 aggregate / layer (s) | Decoder wall (s) | Difference (s) | Difference | Wall repetitions |
|---|---:|---:|---:|---:|---:|
| C1 | 276.183695 | 287.021792 | +10.838097 | +3.924% | 1 |
| C2 | 40.913282 | 47.637037 | +6.723755 | +16.434% | 3 |
| C3 | 29.705566 | 33.235482 | +3.529916 | +11.883% | 3 |

C1 uses one timed repetition because one graph takes nearly five minutes.
C2/C3 show the median of three repetitions. Each timing process first executes
and checks a warmup graph. The timer wraps only `decoder.run(false, {})`.
Initial uploads/allocation, intermediate downloads/checks, and counter queries
are outside the timed interval. Kernel launch/wait, existing runtime logging
and the small CPU sample bookkeeping remain included. The busy-poll runtime
has no fixed settle delay or polling sleep.

| Candidate | Separate cycle-sum profile (s) | Wall relative to profile | Wall samples (s) |
|---|---:|---:|---|
| C1 | 286.858327 | +0.057% | 287.021792 |
| C2 | 47.672956 | -0.075% | 47.637037, 47.627929, 47.649164 |
| C3 | 33.288134 | -0.158% | 33.256804, 33.235482, 33.228246 |

Profiles are separate executions, not counters read inside the wall timer.
C1 reuses its single validation profile; C2/C3 use the median-total profile
pass from three counter runs. Small signed differences include run variation
and do not measure a negative launch overhead.

## Where the difference occurs

The following entries are decoder profile minus historical aggregate, in seconds.
Each C2/C3 breakdown uses one complete median-total pass, so its rows add up.

| Component | C1 delta (s) | C2 delta (s) | C3 delta (s) |
|---|---:|---:|---:|
| Linear GEMMs | +4.075219 | -0.000533 | +0.000600 |
| QK GEMM | +2.406956 | +2.410068 | +0.001052 |
| PV GEMM | +0.334949 | +0.394359 | +0.001075 |
| Head concat | +1.066813 | +1.061451 | +1.170293 |
| KV quantization | +0.232390 | +0.234106 | +0.234221 |
| Extra device reorder | +2.146386 | +2.147089 | +1.987128 |
| KV dequantization | +0.342934 | +0.342051 | +0.000000 |
| Other kernels | +0.068985 | +0.171081 | +0.188199 |
| Total profile difference | +10.674632 | +6.759674 | +3.582568 |

1. The connected graph adds real on-device Q/K/V head reorders. C1/C2 also
   transpose dequantized V for the TCU. The historical sum assumes each isolated
   kernel already has its required input layout; these connections are absent.
2. Historical latency explicitly excludes all dequantization. C1/C2 actually
   execute dynamic KV dequantization inside the graph. C1 static weight
   dequantization remains outside both the historical latency and decoder timer.
3. The shared decoder integration did not select several standalone optimized
   defaults: concat uses baseline instead of `chunk16_packed`; eladd omits
   `ELADD_ROW_COALESCED_CURSOR`; SiLU uses baseline instead of `linear`.
   Dynamic dequant uses baseline instead of `groupwise_fp16`. These sources
   were kept fixed during this comparison. No new kernel optimization is claimed.
4. KV quant uses the same groupwise FP16 implementation, but the decoder fixes
   warp-per-group mapping. The standalone host selects thread-per-group for
   this prefill shape. V also differs in quantization policy: current decoder
   asymmetric versus historical symmetric. Do not attribute the quant gap to
   launch overhead alone.
5. TCU QK is about 9.49 s in both C1/C2 profiles versus 7.08 s historically.
   The kernel variant is `b_colmajor` in both. The specific cause of this gap
   is not isolated by this experiment; memory placement, linked code and cache
   context differ. It cannot be explained solely by the C2 FPGA configuration,
   since C1 shows the same gap.

## Historical baseline and validity

The baseline is the rev5 no-area-normalization E2E figure, including Hadamard.
Its Llama3 B1/S1024 totals are divided by 32 decoder layers. Each candidate has
24 included operation entries, all resolved from measured data: no interpolation
or missing entries. Head-call multipliers are included. The extraction was
cross-checked against the corresponding prepared `total.csv`.

C1 history uses its C1 image. C2 history reuses C1 vector/TCU measurements and
C3 naive GEMMs; the connected C2 uses its own image for the whole graph. C3
history reuses C1 vectors, while its connected graph runs entirely on C3.
All images run at 100 MHz. The existing latency_on_hw database/figures were
not modified or remeasured.

Final decoder outputs pass before and after timing for all three candidates.
Packed KV bytes/scales/zeros match exactly, and all local checks except PV pass.
The known FP16 subnormal-related same-input PV failure remains; these are
diagnostic latency results, not a claim of complete functionality PASS.

## Artifacts

- [Exact comparison values](C1_C3_B1_S1024_comparison.json)
- [Per-operation comparison](C1_C3_B1_S1024_operations.csv)
- [Historical selected rows and provenance](rev5_llama3_b1_s1024_rows.csv)
- Historical source: `composed_results.th16_20261007_rev5_pipeline/llama3_8b/composed.csv`
  and `figure_prepare.th16_20261007_rev5_pipeline/prepare_manifest.llama3_8b.json`.
- Analysis scripts: `build_decoder_compare_20261009/analyze.py` and `report.py`.

- C1 raw timing/profile/verification: `build_llama_decoder_c1_parallel_20261009/results/llama3_b1_s1024_latency_20261009/`.
- C2 raw timing/profile/verification: `build_llama_decoder_c2_parallel_20261009/results/llama3_b1_s1024_timing_20261009/`.
- C3 raw timing/profile/verification: `build_llama_decoder_c3_parallel_20261009/results/prefill_s1024_20261009/`.

The only executable-source change in this measurement task is the host option
`--profile-repetitions N` (default: `--repetitions`; zero disables extra counter
passes). C1 uses `--repetitions 1 --profile-repetitions 0` to reuse its existing
validation profile. Kernel binaries and RTL were not changed for this comparison.
