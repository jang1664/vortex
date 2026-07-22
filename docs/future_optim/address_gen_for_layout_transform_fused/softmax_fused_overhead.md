# Softmax Layout-Fused Address Overhead

## Conclusion

Use the new DMA-free `rev2` pair for address-generation experiments:

- `softmax/rev2`: row-major input and output addressing.
- `softmax_layout_fused/rev2`: GEMM-C tiled input addressing and GEMM-A tiled output addressing.

Both variants use the same cached SIMT softmax body, one 32-thread block per
row, one global input load per active logical element, one `exp` evaluation per
active logical element, causal-range clamping, the same LMEM reductions, and
direct SIMT stores. Both hosts also use the same deterministic score generator.
The per-row address setup and accessor are the only layout-dependent parts.

The existing `rev1` pair remains useful as a naive control, but it reads each
input three times and evaluates `exp` twice. Those costs hide the address
overhead that this project is intended to measure. Existing optimized variants
are not a fair pair because their DMA, launch, reduction, and cache strategies
differ.

As a control, B1/H1/Q1/K32 causal passed in both `rev1` kernels. Baseline
`rev1` retired 85,665 instructions and fused `rev1` retired 91,364, whereas
baseline `rev2` retired only 36,600. This confirms that `rev1` compute and
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

Run the committed small matched regression with
`make -C tests/regression run-simx-softmax-rev2-pair` from a configured build
directory. It covers co-resident K32 rows and causal K33 rows with a
non-tile-aligned requested stride.

| Shape and options | Baseline instructions | Fused instructions | Instruction overhead | Baseline cycles | Fused cycles | Cycle overhead |
|---|---:|---:|---:|---:|---:|---:|
| B1 H1 Q1 K32, causal | 36,600 | 38,560 | 5.36% | 33,143 | 36,038 | 8.73% |
| B1 H1 Q4 K32, no mask | 95,105 | 107,905 | 13.46% | 64,865 | 80,920 | 24.75% |
| B1 H2 Q4 K32, causal | 119,964 | 136,124 | 13.47% | 97,249 | 112,676 | 15.86% |
| B1 H1 Q3 K33, stride 64, causal | 64,008 | 70,596 | 10.29% | 53,632 | 59,484 | 10.91% |
| B1 H1 Q4 K64, no mask | 114,518 | 128,982 | 12.63% | 66,630 | 82,820 | 24.30% |

Causal clamping reduces both useful computation and input-address generation.
It does not eliminate output-address generation because masked and padded
columns must still be zeroed. The K33 case with physical stride 64, for example,
generates tiled store addresses through column 63.

## Hardware Address-Generator Prototype

The `rev2_addrgen` prototype replaces only the layout-fused accessor's tiled
offset arithmetic. The row-major `softmax/rev2` baseline contains no address-
generator instruction. A generated-instruction scan found zero CUSTOM0 funct7
`0x04`/`0x05` instructions in the baseline and nine static instances in the
address-generator fused kernel.

Initial `simx` results are:

| Shape and options | Baseline cycles | Fused rev2 cycles | Fused rev2_addrgen cycles | Original gap | New gap | Gap reduction |
|---|---:|---:|---:|---:|---:|---:|
| B1 H1 Q4 K32, no mask | 64,869 | 80,920 | 74,159 | 16,051 | 9,290 | 42.1% |
| B1 H1 Q4 K64, no mask | 66,714 | 82,820 | 75,909 | 16,106 | 9,195 | 42.9% |
| B1 H1 Q3 K33, stride 64, causal | 53,717 | 59,484 | 59,559 | 5,767 | 5,842 | -1.3% |

All three variants passed their reference checks. The short causal case does
not amortize the load/store stream configuration commands, so the prototype is
75 cycles slower than the original fused accessor there. A later kernel policy
may need to bypass the generator below a measured active-element threshold.

The `simx` implementation models command execution and address values but not
depth-two queue occupancy or pop blocking, so the cycle reductions above remain
software-model estimates. The RTL uses independent per-thread load and store
queues, with all live thread streams able to enqueue in parallel. Its focused
VCS unit test passes at the target four-warp, 32-thread shape, and the following
end-to-end `xrt-vcs-sim` cases pass without deadlock:

| Shape and options | Max difference | Instructions | Cycles |
|---|---:|---:|---:|
| B1 H1 Q2 K32, no mask | 0.000015 | 63,774 | 37,305 |
| B1 H1 Q3 K33, stride 64, causal | 0.000031 | 70,358 | 44,527 |

The linked worktree does not contain populated third-party submodules. These
runs exported `THIRD_PARTY_DIR=/home/jaeyongjang/project.local/vortex_fpint/third_party`
so the xrt-vcs build reused the populated dependencies from the primary
checkout.

An additional B1/H1/Q3/K33 causal case with requested stride 40 passed in both
variants after both hosts rounded the physical extent to 64 elements. This
locks the matched-layout contract for a non-tile-aligned requested stride.

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
