# rev8 decode vector latency: full-cache K transpose

Analyzed 2026-10-20 from the completed `th16_20261017_rev8_pipeline` artifacts. No production code, suites, measurements, or plots were modified.

## Conclusion

The large C1/C2 vector bars are dominated by `attn_k_transpose::head_transpose`, introduced for FPFP attention. The other standalone vector contributions are identical to C3 because this suite reuses their measurements. This is not evidence that the C1/C2 vector execution hardware is generally slower.

The chart classifies this explicit transpose as **vector**, although its purpose is layout conversion. Its **layout** category specifically represents positive C4 layout-fused overhead relative to C3; it does not include every operation that changes layout.

## B1, context 8192: exact plotted component values

Seconds per output token, averaged across 128 decode steps, covering all 32 layers. These are aggregated FPGA-cycle estimates, not measured whole-model wall times.

| Model | Candidate | Plotted vector | K transpose within vector | Other vector | Separate plotted layout |
|---|---|---:|---:|---:|---:|
| Llama2-7B | C1 | 196.818245 | 193.771754 | 3.046492 | 0 |
| Llama2-7B | C2 | 196.818245 | 193.771754 | 3.046492 | 0 |
| Llama2-7B | C3 | 3.046492 | 0 | 3.046492 | 0 |
| Llama2-7B | C4 | 3.046492 | 0 | 3.046492 | 0.221313 |
| Llama3-8B | C1 | 49.687832 | 47.741750 | 1.946081 | 0 |
| Llama3-8B | C2 | 49.687832 | 47.741750 | 1.946081 | 0 |
| Llama3-8B | C3 | 1.946081 | 0 | 1.946081 | 0 |
| Llama3-8B | C4 | 1.946081 | 0 | 1.946081 | 0.142790 |

K transpose is **98.45%** of C1/C2 vector latency for Llama2, **96.08%** for Llama3. C4's equality in the vector column follows the plot's attribution of fused overhead to layout; it does not mean all C4 kernels have identical raw measurements.

The per-workload denominator used by the figure is C4 E2E latency: 6.60342783375 s for Llama2 B1/8K and 4.57511711875 s for Llama3 B1/8K. Figure CSV cells are already normalized by that denominator. The table reverses that normalization and follows `plot.py::_build_gemm_layout_stack` to separate C4 layout overhead. [breakdown.json](breakdown.json) contains all decode batches/context lengths and source paths.

## Why C1/C2 need the current extra operation

`tools/workload/gen_kernel_cfgs.py::_apply_fpfp_gemm` replaces the FP16 GEMM backend and inserts `attn_k_transpose` immediately before QK. FPFP accepts row-major B and has no transpose mode:

- Dequantized K: `[S, D]`.
- QK product: `[M, D] x [D, S]`.
- Therefore the current software materializes K as `[D, S]` before calling FPFP.

The standalone command is `head_concat -batch 1 -seq S -heads 1 -headdim 128 -mode 2`. The name `head_concat` identifies the executable; mode 2 is transpose, not concat.

C1 and C2 both use FPFP attention in rev8. C2 reuses C1's vector measurements. C3/C4 use their FPINT attention layouts and have no corresponding explicit K-transpose node. The decoder also inserts a transpose after K dequantization in its FPFP branch; this node is not merely an accidental suite-only addition.

## It is a slow measured kernel, not a 128x aggregation mistake

Original C1 raw rows at `S=8192`, 100 MHz:

| Model's measurement | Core cycles | Device time | Host measured time |
|---|---:|---:|---:|
| Llama2 | 18,869,663 | 188.69663 ms | 188.73514 ms |
| Llama3 | 18,871,068 | 188.71068 ms | See raw log |

The Llama2 latency log reports one timed iteration and 25,204,194 retired instructions. Its later power measurement repeats the kernel 53 times; those repeated-power cycles are **not** the latency value selected in raw_db. The raw cycle count and host latency agree.

Per-token transpose calls are `num_layers * batch * num_key_value_heads`:

- Llama2 B1: `32 * 1 * 32 = 1024`.
- Llama3 B1: `32 * 1 * 8 = 256`.

Thus 188.7 ms per head already predicts about 193.2 s or 48.3 s per output token. The precise plotted values average lengths 8193 through 8320 and their measured/interpolated latencies.

The Llama2 composed CSV was checked directly: 128 token rows per C1/C2 variant, each with `effective_calls=1024`; eight measured rows and 120 estimated rows. Summing weighted latency and dividing by 128 reproduces **193.77175352 s**. The C2 rows point to C1's raw measurements. Multiplication by heads/layers is intentional, and the 128 tokens are averaged rather than left as an extra multiplier. Nearby measured lengths remain slow: S8193/S8225/S8257/S8289/S8320 take approximately 18.66/19.51/19.02/19.09/18.57 million cycles in Llama2, so the result is not solely an interpolation artifact at S8192.

## Why the implementation is inefficient

`tests/regression/head_concat/reorder.h::kernel_head_reorder` executes scalar uint16 loads and stores:

```cpp
s = (i / headdim) % seq;
d = i % headdim;
target = (matrix * headdim + d) * seq + s;
output[target] = input[i];
```

With TH16, D128 and S8192, adjacent lanes read consecutive 2-byte input elements but store to output addresses **16 KiB apart** (`2*S`). For a group of 16 lanes at the same token, this means 16 distinct output cache lines rather than one contiguous store region. With the current low-bit mapping, a 16 KiB step is 256 cache lines and preserves both the relevant Dcache set index and HBM port/bank selection. This creates poor store coalescing and severe set pressure. These are static address properties; this investigation does not claim a new waveform-derived percentage of stalls for this kernel.

The `chunk16_packed` variant optimizes concat mode only. Transpose mode still dispatches to this shared scalar helper, in both standalone and decoder builds. It does not stage a tile in LMEM to make both global reads and writes contiguous. It also performs index arithmetic per FP16 element. The measured instruction count confirms substantial work, but the relative costs of arithmetic, write traffic, and cache stalls have not been separately measured here.

Each decode step repeats this operation for the entire growing K cache, not just the newly appended token. That explains the context-length dependence:

| B1 model | Context 1K K transpose (s/token) | 8K | 32K |
|---|---:|---:|---:|
| Llama2 | 25.816109 | 193.771754 | 788.744329 |
| Llama3 | 6.651814 | 47.741750 | 192.384782 |

## Recommended correction scope

1. A tiled transpose using LMEM can improve this general operation without changing the FPFP RTL interface. It should make global stores contiguous and serve arbitrary prefill/decode sizes, rather than specialize S=1.
2. The K dequantizer can instead emit the FPFP-required `[D,S]` layout directly, eliminating a separate full-cache transpose pass. This requires measuring the changed dequantization implementation; merely deleting the transpose from the estimate would hide real work. The latency model's existing treatment of dequantization must remain explicit.
3. Rename or reclassify explicit transpose in the plot if desired. This changes presentation only and cannot fix E2E latency.

No optimization or remeasurement was performed in this analysis.

## Evidence paths

- `figure_prepare.th16_20261017_rev8_pipeline/{llama2_7b,llama3_8b}_e2e_no_area_norm_gemm_layout_vector_stacked_by_name_backend_*/{excel_figure_data.csv,total.csv}`.
- `outputs_llama{2,3}_main.th16_20261017_rev8_pipeline/C1/raw_db.csv`.
- Llama2 S8192 latency log: `outputs_llama2_main.th16_20261017_rev8_pipeline/C1/runs/20261017T045906303643Z/logs/d307ba1d6c.log`.
- Llama3 S8192 latency log: `outputs_llama3_main.th16_20261017_rev8_pipeline/C1/runs/20261017T045906422358Z/logs/d307ba1d6c.log`.
- `composed_results.th16_20261017_rev8_pipeline/llama2_7b/composed.csv`.
- Generator: `tools/workload/gen_kernel_cfgs.py::_apply_fpfp_gemm`.
- Kernel: `tests/regression/head_concat/reorder.h`; dispatch in `kernel.chunk16_packed.cpp`.
- Decoder: `tests/regression/llama_decoder_common/decoder.cpp`, FPFP K transpose after dequant; `device_concat.cpp` reuses the standalone implementation.
