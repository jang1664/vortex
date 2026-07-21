# Hardware Address Generator for Layout-Fused Kernels

Implementation branch: `feat/layout-fused-address-generator`

## Summary and Evaluation

The proposal is promising, but RTL implementation proceeds only after proving
that residual address-generation work is still a significant bottleneck in the
currently optimized kernels.

The hardware can remove repeated affine arithmetic, division, remainder, and
layout decoding. Configuration and `pop_*_addr` instructions still consume
issue bandwidth, however, and the initial TH32 implementation requires three
32-lane generators plus about 12 KiB/core of address payload at queue depth
four. The expected speedup must therefore be measured rather than assumed.

The v1 feature target is `eladd_layout_fused`, because it naturally requires
two load streams and one store stream. `head_concat_layout_fused` is the
low-address-overhead control. Kernels needing additional simultaneous streams
are deferred.

## Architecture and ISA

- Every architectural thread owns independent `LD0`, `LD1`, and `ST`
  generators, descriptors, counters, and queues.
- The physical implementation is vector-banked by warp and lane. Three
  parallel TH32 producers advance the streams independently with fair
  round-robin warp selection.
- Each descriptor is a three-dimensional affine loop:
  `address = base + sum(index[d] * stride[d]) mod 2^64`. Dimension zero is
  innermost. Strides are signed 64-bit byte values and bounds are unsigned
  32-bit values.
- The unit is a dedicated, optional `EX_AGEN` execution unit guarded by
  `EXT_ADDR_GEN_ENABLE` and initially enabled only in a derived TH32
  configuration.
- Queue depth starts at four entries per thread and stream. The final depth is
  the smallest of 2, 4, and 8 that keeps empty-pop stalls below 5% while
  meeting timing and area gates.

The instructions use raw R-type `CUSTOM0` encodings. HW EXP remains at
`funct7=0x03`; `LD0`, `LD1`, and `ST` use `funct7=0x04`, `0x05`, and `0x06`.

| `funct3` | Operation | Operands |
| ---: | --- | --- |
| 0 | `CFG_BASE` | `rs1=64-bit byte base` |
| 1-3 | `CFG_DIM0..2` | `rs1=signed stride`, `rs2=unsigned bound` |
| 4 | `START` | none |
| 5 | `RESET` | none |
| 6 | `POP` | integer result in `rd` |
| 7 | reserved | none |

The kernel API exposes `addrgen_set_base`, `addrgen_set_dim`,
`addrgen_start`, `addrgen_reset`, `pop_ld_addr(0|1)`, and `pop_st_addr`.
Generator and dimension arguments are compile-time constants. All intrinsics
use volatile assembly and memory clobbers. LLVM changes are out of scope.

Configuration writes shadow state. `START` atomically publishes a complete
descriptor and clears its live counters. The lifecycle is
`IDLE -> CONFIGURED -> RUNNING -> DRAINING -> IDLE`. `RESET` is always
accepted and flushes one selected stream. Invalid reconfiguration does not
mutate state and raises a debug error.

`POP` is blocking and atomic over the active thread mask. It fires only when
every active lane has an address, then pops one address from each active lane.
Masked lanes neither pop nor write `rd`. An exhausted active lane blocks by
architectural contract. An unready pop must not occupy a shared request slot
or block ready warps. Normal writeback and scoreboard dependencies order the
following load or store; `is_wstall` and explicit WAIT instructions are not
used.

## Implementation Sequence

1. Measure the current optimized `eladd_layout_fused` `tile_chunk32` kernel on
   TH32. Classify dynamic address/control instructions and build a matched
   recurrence oracle that preserves memory access order. Stop before RTL
   unless address/control is at least 20% of retired instructions and the
   setup/pop-adjusted speedup projection is at least 1.20x.
2. Add guarded raw-instruction intrinsics, trace/disassembly names, and simx
   functional semantics for descriptors, carry, masks, reset, and exhaustion.
3. Implement the banked descriptors, queues, three parallel vector producers,
   blocking pop path, performance counters, and complete optional `EX_AGEN`
   pipeline integration.
4. Add an address-generator `eladd_layout_fused` variant. Configure and drain
   one `MT=128` segment at a time because a final partial-M segment has a
   different GEMM-C stride. Preserve the current `K % 32 == 0` requirement.
5. Run focused RTL unit tests, decode/execute tests, simx tests, xrt-vcs
   blackbox tests, synthesis, and default-configuration regressions before
   merging into `fpint`.

## Verification and Acceptance Gates

Directed tests cover exact three-dimensional carry order, bounds zero and one,
negative and large strides, 64-bit wraparound, queue full/empty behavior,
divergent masks, atomic pop, stream independence, multi-warp fairness, reset at
every lifecycle point, and no head-of-line blocking from an empty pop.

Kernel integration covers `M={1,127,128,129,255}`, `K={32,64,160}`, repeated
power iterations, logical-thread reuse, and bit-exact output against the
current optimized kernel. Existing default kernels and HW EXP instructions are
negative-regression tests.

The implementation is mergeable only when it satisfies all of these gates:

- At least 70% fewer classified address-arithmetic instructions.
- At least 15% fewer total retired instructions.
- At least 20% fewer kernel cycles than current optimized eladd.
- Empty-pop stalls below 5% of kernel cycles.
- No more than 2% regression with the feature disabled.
- TH32 synthesis meets 100 MHz with non-negative slack.
- Added LUT and FF utilization are each at most 15%, and address-generator
  storage uses at most four BRAM36 equivalents per core.

## v1 Boundaries

- XLEN=64 and TH32 only.
- Three affine dimensions and exactly two load streams plus one store stream.
- Loads and stores still execute through the normal LSU using popped integer
  addresses.
- No automatic memory operation, gather/scatter, data-dependent addressing,
  compiler scheduling, or context-preemption support.
- A successful eladd result validates the mechanism; it does not imply that
  every `*_layout_fused` mapping is supported.
