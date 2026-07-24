# Layout-fused factorized Hadamard optimization

## Scope

The factorized R4 transform for Llama3-8B uses:

- `dim = 14336`
- `base_k = 28`
- butterfly width `14336 / 28 = 512`
- a 512-point butterfly followed by a 28-by-28 base transform

The original standalone implementation was two kernels:

1. `hadamard -K 28`
2. `hadamard_base -base-k 28 -width 512`

That was not a fair baseline for measuring layout overhead because the
layout-fused implementation performed both stages in one launch. Standalone
now performs the butterfly and base transform in one `hadamard -K 28` kernel
and writes row-major output. Layout-fused performs the identical computation
while reading and writing GEMM-A tiled layout.

Factorized is the default transform mode. Zero padding remains available as an
explicit approximation:

- standalone: pass `-K 0`
- layout-fused: pass `--hadamard-variant zero_padding`

For a power-of-two dimension, factorization selects `base_k = 1`. The
standalone workload generator emits one `hadamard` kernel, and the
layout-fused kernel takes its `base_k == 1` scale/write path. No base-transform
matrix multiplication or `hadamard_base` launch is performed.

All cycle results below were measured on the C4 FPGA alias with the configured
`adaptive_multiwarp_row` layout-fused mapping.

## Problems

### Repeated FP16 rounding

The standalone boundary materializes the butterfly result as FP16 before the
base transform. The original fused kernel preserved this boundary by performing
the same float-to-FP16-to-float conversion inside every `out_k` dot product.

For `base_k = 28`, one butterfly intermediate was therefore converted 28 times.

The optimized kernel rounds and rescales every butterfly intermediate once,
stores the rounded float value back in local scratch, and reuses it for all
base-transform outputs. This preserves the standalone rounding order.

### Repeated local-memory loads

The original loop computed one base-transform output at a time. Each scratch
intermediate was loaded again for every `out_k`.

The optimized loop keeps a thread on one butterfly column and computes four
`out_k` values together. One scratch load updates four accumulators. Four
accumulators fit without the excessive register pressure expected from wider
groups, while reducing scratch traffic by up to four times.

The old standalone `hadamard_base` had the same reuse problem in global
memory: one work item computed one `out_k`, so it loaded and converted the
same input value again for all 28 output rows. Its optimized mapping assigns a
work item to one `(row, butterfly_column)` and computes four `out_k` values
together. This reuses each input load and FP16-to-float conversion across four
accumulators. A scalar tail preserves correctness for base sizes not divisible
by four.

### Narrow factorized widths

The adaptive launch initially selected four warps solely from the number of
rows. A mixed-radix edge case with `base_k = 3` has a butterfly width of only
32, so only one warp has base-transform work. The four-warp launch produced
incorrect results for this case.

Factorized mode now selects multiple warps only when its butterfly width is
larger than one hardware warp. The `base_k = 3`, width-32 case therefore falls
back to one warp.

## Rejected experiment

Converting the base matrix to float in local memory once per block was tested.
It caused a severe hardware stall and was rejected. Every lane in a warp reads
the same coefficient, which serialized on the local-memory bank path. Keeping
the small FP16 matrix in global/cache memory was substantially faster.

## C4 results

### Historical two-kernel standalone base-transform optimization

| Rows | Original base | Grouped-4 base | Reduction |
| ---: | ---: | ---: | ---: |
| 1 | 4,898,044 | 1,371,862 | 72.0% |
| 2 | 9,644,196 | 2,672,447 | 72.3% |
| 4 | 19,247,405 | 5,268,902 | 72.6% |

This optimization was useful for diagnosing the base-transform bottleneck, but
the remaining second launch and intermediate tensor still made it an unfair
layout-overhead baseline.

### Fair row-major standalone versus layout-fused factorized

Both sides now use one kernel with the same butterfly, one-time FP16 rounding,
and grouped-four base transform. Standalone reads and writes row-major data;
layout-fused reads and writes GEMM-A tiled data.

| Rows | Standalone row-major | Layout-fused tiled | Layout overhead |
| ---: | ---: | ---: | ---: |
| 1 | 1,732,718 | 1,753,356 | 1.19% |
| 2 | 3,389,195 | 3,419,310 | 0.89% |
| 4 | 6,517,375 | 6,763,123 | 3.77% |
| 1024 | 1,675,688,785 | 1,708,654,905 | 1.97% |

The fair comparison exposes a 0.89% to 3.77% layout overhead. The previous
comparison incorrectly credited layout fusion with eliminating the second
kernel launch and intermediate global-memory tensor; standalone now receives
the same compute-fusion optimization.

### Factorized fused versus zero-padding fused

| Shape | Zero padding | Factorized | Factorized/zero-padding |
| --- | ---: | ---: | ---: |
| Generation, M1/D14336 | 914,982 | 1,753,356 | 1.916x |
| Prefill, M1024/D14336 | 818,898,544 | 1,708,654,905 | 2.087x |

Factorized mode is now efficient relative to the equivalent standalone exact
transform, but it still performs the 28-by-28 base transform. Zero padding only
runs the 16,384-point fast butterfly and is therefore faster, but factorized is
the default because it implements the intended SpinQuant transform exactly.

## Verification

The final kernel passed the C4 hardware suite for:

- Llama3-8B `base_k = 28`
- Llama2-7B `base_k = 172`
- mixed-radix `base_k = 3`, including the scalar tail
- power-of-two `base_k = 1`
- row-major and GEMM-A tiled inputs
- zero-padding regression cases

The new row-major single-kernel standalone path additionally passed C4
bit-exact checks for `base_k = 3` and Llama3-8B `base_k = 28`. The workload
generator now emits one standalone R4 Hadamard row and no `hadamard_base` row.

The workload-generator regression suite passed all 29 tests. A C4 benchmark
without `--hadamard-variant` measured 1,753,335 cycles for M1/D14336, matching
the explicit factorized result (1,753,356 cycles) and confirming the runtime
default.

The build directory was reconfigured before the final measurements. An older
generated Makefile did not contain the source-tree
`HADAMARD_LAYOUT_FUSED_VARIANT_TAG=2` selection and silently built the
single-warp kernel.
