# Softmax Layout-Fused Address Overhead

## Conclusion

Use the new DMA-free `rev2` pair for address-generation experiments:

- `softmax/rev2`: row-major input and output addressing.
- `softmax_layout_fused/rev2`: GEMM-C tiled input addressing and GEMM-A tiled output addressing.

Both variants use the same cached SIMT softmax body, one 32-thread block per
row, one global input load per active logical element, one `exp` evaluation per
active logical element, causal-range clamping, the same LMEM reductions, and
direct SIMT stores. The per-row address setup and accessor are the only
layout-dependent parts.

The existing `rev1` pair remains useful as a naive control, but it reads each
input three times and evaluates `exp` twice. Those costs hide the address
overhead that this project is intended to measure. Existing optimized variants
are not a fair pair because their DMA, launch, reduction, and cache strategies
differ.

As a control, B1/H1/Q1/K32 causal passed in both `rev1` kernels. Baseline
`rev1` retired 84,001 instructions and fused `rev1` retired 89,700, whereas
baseline `rev2` retired only 36,696. This confirms that `rev1` compute and
memory redundancy is large enough to obscure the target overhead.

## Configuration

- Simulator: `simx`
- Hardware shape: 1 core, 4 warps/core, 32 threads/warp
- Cache: 32 KiB I-cache and 32 KiB D-cache
- Kernel configuration: `configs/improve_th32_tcol32_dcache_simx.sh`
- DMA: not used by either `rev2` kernel
- Exponential: identical software `vx_expf` in both kernels
- Launch: one 32-thread block per row; multiple row blocks can be co-resident

The normal HW-exp configuration cannot be used for this `simx` comparison:
`VX_ENABLE_HW_EXPF` emits a custom exponential instruction that the `simx`
decoder does not implement. The comparison config therefore omits that macro
for both variants.

## Results

All cases passed their CPU-reference checks.

| Shape and options | Baseline instructions | Fused instructions | Instruction overhead | Baseline cycles | Fused cycles | Cycle overhead |
|---|---:|---:|---:|---:|---:|---:|
| B1 H1 Q1 K32, causal | 36,600 | 38,560 | 5.36% | 33,143 | 36,038 | 8.73% |
| B1 H1 Q4 K32, no mask | 95,172 | 107,905 | 13.38% | 64,888 | 80,920 | 24.71% |
| B1 H2 Q4 K32, causal | 119,922 | 136,106 | 13.50% | 97,523 | 112,354 | 15.21% |
| B1 H1 Q3 K33, stride 64, causal | 63,988 | 70,596 | 10.33% | 53,716 | 59,485 | 10.74% |
| B1 H1 Q4 K64, no mask | 114,410 | 128,982 | 12.74% | 66,653 | 82,820 | 24.26% |

Causal clamping reduces both useful computation and input-address generation.
It does not eliminate output-address generation because masked and padded
columns must still be zeroed. The K33 case with physical stride 64, for example,
generates tiled store addresses through column 63.

## Static Code Evidence

The optimized kernel functions have the following static sizes:

- Row-major: 460 instructions, 1,840 bytes.
- Layout-fused: 570 instructions, 2,280 bytes.
- Difference: 110 instructions, or 23.91%.

Relative to the row-major function, the fused function contains notably more
integer address machinery:

- `mul`: 12 versus 3
- `slli`: 45 versus 30
- `srli`: 26 versus 21
- `sll`: 3 versus 0
- `and`: 7 versus 3
- unsigned division: 1 versus 0

It also has 15 more static loads and 15 more static stores, consistent with
additional register pressure and spills from the inlined tiled-offset logic.
The floating-point operation counts and six block barriers are unchanged.

## What To Optimize First

1. Offload the per-element GEMM-C load and GEMM-A store offset sequences. They
   are on every logical load/store and every padded output store, and dominate
   the stable absolute delta per row.
2. Offload the remaining per-row descriptor setup. `rev2` already hoists tile
   masks, row prefixes, group strides, and matrix sizes, leaving one row
   quotient/remainder and descriptor construction per row.
3. Avoid generating padded-store addresses one element at a time. A store
   generator should naturally continue through the physical bound and emit the
   tiled sequence without scalar loop arithmetic.
4. Re-measure register spills after replacing inline address calculations with
   `pop_ld_addr` and `pop_st_addr`. Some cycle gain should come from lower
   register pressure in addition to the eliminated arithmetic.

The proposed per-thread load/store address queues match this workload well.
The generator should accept separate input and output layout descriptors,
because softmax reads GEMM-C layout and writes GEMM-A layout. Queue setup should
be issued once per row or persistent row range; issuing a full descriptor for
every element would replace arithmetic overhead with command overhead.

## Pointer-Recurrence Experiment

A software cursor experiment computed each loop's first tiled address once and
then advanced it by the precomputed tiled-group stride. The row-major accessor
still compiled to its original direct indexing. All correctness cases passed,
but the optimization was not retained because it did not improve the complete
workload set:

| Case | Fused instruction change | Fused cycle change |
|---|---:|---:|
| B1 H1 Q1 K32, causal | +0.89% | +1.10% |
| B1 H1 Q4 K32, no mask | +0.42% | -2.20% |
| B1 H2 Q4 K32, causal | +1.97% | +3.66% |
| B1 H1 Q3 K33, stride 64, causal | +0.42% | +2.72% |
| B1 H1 Q4 K64, no mask | -1.39% | -2.36% |

The recurrence only amortizes its setup for lanes that execute multiple loop
iterations. With short or causal rows, initializing per-lane load, active-store,
and padding-store cursors costs more than the removed repeated offset math.
Attempts to skip inactive cursor setup added SIMT control-flow cost and regressed
the measured cases further. The source was restored to the simpler inlined
offset implementation.

## Caveats

- The original co-resident-block failure was an LMEM allocation macro bug, not
  an Omega routing or tag-width failure. `__local_mem(size)` used `size` without
  parentheses, so `__local_mem(score_bytes + reduce_bytes)` expanded to
  `base + group_id * score_bytes + reduce_bytes`. Adjacent K32 blocks were only
  128 bytes apart despite requesting 256 bytes, and one block's reduction area
  overlapped the next block's score area. Parenthesizing the macro argument
  restores the intended block stride.
- The exact B1/H1/Q2/K32 concurrent-block regression also passes `xrt-vcs-sim`
  with 32 threads and both `LMEM_REQ_OMEGA_ENABLE` and
  `LMEM_RSP_OMEGA_ENABLE`: 57,238 instructions, 35,471 cycles, and maximum
  absolute error 0.000061. The earlier LMEM tag-width issue remains a distinct,
  already-fixed RTL problem.
- The experiments are intentionally small because RTL-scale simulation cost is
  high. Larger hardware runs should be used only after the address-generator
  path is functionally stable.
- Instruction delta is the cleanest current measure because the shared compute
  body makes the accessor the only semantic difference. Cycle delta also
  includes secondary effects such as spills, cache timing, and reduced IPC.
