# Vector Kernel Optimization Details

Last updated: 2026-07-12

## Purpose

This document explains how each kernel was optimized, why the transformation
helps on the current Vortex FPGA configuration, and which implementation is
selected by default. The original implementations remain selectable through
application-specific Makefile variants.

Unless noted otherwise, hardware results use:

```sh
./ci/run_black.sh hw \
  --fpga-bin naive_gemm_simd_th16_tcol32_hwexp_dcache \
  --app <application> --args "<arguments>"
```

The primary metric is the FPGA cycle count reported by `main.cpp`. Prepack
time and `bench_main.cpp` end-to-end timing are not included.

## Summary

| Application | Selected variant | Main optimization | Cycle reduction |
| --- | --- | --- | ---: |
| `sgemm_tcu` | `b_colmajor` | Prepack B in the fragment-native column-major layout | 29.3% |
| `softmax` | `dma_serial` | Safe serialized DMA programming with four-warp compute | 20.8-24.3% |
| `softmax_layout_fused` | `opt_warp` | Correct one-warp-per-row launch | 26.1-35.5% |
| `kv_cache_quant_w4a16` | `groupwise` | Compute quantization parameters once per group | 96.9% |
| `kv_cache_dequant_w4a16` | `packed_pair` | Decode both nibbles and store two FP16 values together | 4.2% |
| `kv_cache_quant_layout_fused_w4a16` | `baseline` | Warp candidate rejected because layout work was replicated | Candidate 2.04x slower |
| `rope_layout_fused` | `task_chunk16` | Amortize flattened-index and layout decoding over 16 pairs | 39.3-45.7% |
| `head_concat_layout_fused` | `chunk16_packed` | Amortize tile decoding and use paired FP16 copies | 91.9% |
| `eladd_layout_fused` | `tile_chunk32` | Process one native GEMM-C microtile per task | 35.0% |
| `rms_norm_layout_fused` | `shuffle_warp` | Replace LMEM tree reduction with warp shuffles | 11.7% |
| `elmul_layout_fused` | `linear_same_layout` | Traverse identical physical tile layouts linearly | 56.0% |
| `silu_layout_fused` | `linear_tiled` | Apply SiLU directly over the physical tiled slot | 12.8% |
| `detile_output` | `packed_pair` | Copy two FP16 elements per 32-bit transaction | 50.6% |
| `tile_input_a` | `packed4` | Copy four FP16 elements per native RV64 transaction | 51.0% |

## 1. sgemm_tcu

### Original behavior

The baseline supplied B in row-major order. Each warp had to assemble the B
fragment into the order expected by `load_matrix_sync`. The kernel already
used WMMA directly, so the largest avoidable cost was fragment preparation and
addressing rather than the matrix multiply itself.

### Selected optimization: `b_colmajor`

B is packed on the host into the column-major order consumed by the TCU
fragment loader. The device then performs aligned direct fragment loads,
removing repeated row-to-column packing from every K iteration.

The host retains the original row-major B for CPU reference calculation. The
prepack operation is intentionally outside the measured kernel latency.

### LMEM experiments

Several variants stage reusable A and B panels in LMEM:

- `lmem` and `lmem_b_colmajor`: 2x2 warp supertiles with all threads
  interleaving aligned staging transfers.
- `kstage4`: stage four K fragments per barrier pair.
- `kstage4_wide64`: combine four-fragment staging with native RV64 transfers.
- `kstage4_n2` and `kstage4_m2n2`: increase accumulator-fragment reuse.

All-thread interleaved loading was substantially better than dedicated
producer warps, but the correct LMEM variants remained slower than direct
column-major loads. Staging and two workgroup barriers outweighed global-load
reuse on the tested FPGA. Multi-accumulator variants also produced one-ULP
FP16 differences and increased register pressure.

### Result

`b_colmajor` reduced the representative shape from 787,982 to 557,470 cycles,
a 29.3% reduction. It is the default; all LMEM experiments remain selectable.

## 2. softmax

### Original behavior

`rev1` uses an LMEM reduction. The existing `opt_align` candidate attempts to
cache rows and exponentials and use DMA, but concurrent DMA programming from
multiple warps corrupts rows after the first one on the current descriptor
frontend.

### Experiments

- `opt_align`: very low reported cycles but incorrect output; rejected.
- `dma_row`: one warp and one row per block. This is correct, but leaves three
  core warps unused and issues many small DMA commands.
- `dma_serial`: retains four-warp row computation, but thread 0 programs the
  four row DMA descriptors sequentially.

`dma_serial` avoids concurrent descriptor-MMIO races while preserving
four-row compute concurrency, cached exponentials, and shuffle reductions.

### Result

- Decode: 3,325,181 to 2,515,641 cycles, 24.3% faster.
- Masked prefill: 155,536,936 to 123,181,677 cycles, 20.8% faster.
- A partial masked row with `Q=3`, `K=130` also passes.

`dma_serial` is the default.

## 3. softmax_layout_fused

### Original behavior

The optimized device kernel is designed around one warp per row, but a
singular/plural macro mismatch in the host selected a 64-thread block. This
made one row occupy all four warps of the core and prevented independent rows
from overlapping execution.

### Selected optimization: `opt_warp`

The selector and host macro were made consistent. `opt_warp` launches one
16-thread warp per row, allowing four independent row blocks to reside on the
four-warp core. The existing tiled layout and softmax algorithm are preserved.

### Result

- Decode: 3,196,292 to 2,363,601 cycles, 26.1% faster.
- Masked prefill: 139,200,932 to 89,824,199 cycles, 35.5% faster.

## 4. kv_cache_quant_w4a16

### Original behavior

The baseline assigns work per packed output byte. For every two output
nibbles, it rescans the corresponding quantization group to calculate min,
max, scale, and zero point. A group of 128 values is therefore scanned many
times for parameters that are identical across the group.

### Selected optimization: `groupwise`

One warp owns one quantization group:

1. Lanes interleave loads across the group.
2. Min and max are reduced with warp shuffles.
3. Scale and zero point are computed once and written once.
4. The same lanes quantize and pack the group using the broadcast parameters.

Separate task mappings support both quantization directions:

- `QDIR=1`: one task per row and N group.
- `QDIR=0`: one task per K group and N pair.

Partial groups use bounded loops, and unsupported odd packing cases retain a
safe baseline fallback.

### Result

The primary `K=2048`, `N=128`, `QBLK=128`, `QDIR=1` shape improved from
289,624,222 to 8,918,465 cycles, a 96.9% reduction. Partial QDIR0 and QDIR1
groups also pass.

## 5. kv_cache_dequant_w4a16

### Original behavior

The baseline handles quantized values individually. Adjacent values share one
packed byte and often the same quantization parameters, but the byte and
parameter-index work are repeated.

### Selected optimization: `packed_pair`

Each task handles both nibbles in one packed byte:

- Load the packed byte once.
- Reuse scale and zero point when both values belong to the same group.
- Dequantize both values.
- Emit the two FP16 results with one aligned 32-bit store.

Boundary logic preserves QDIR0 and partial-group behavior.

### Result

The primary shape improved from 7,811,805 to 7,486,701 cycles, a 4.2%
reduction. The gain is smaller than quantization because dequantization did not
contain the baseline's repeated full-group scans.

## 6. kv_cache_quant_layout_fused_w4a16

### Attempted optimization: `qparam_warp`

The candidate parallelizes each min/max group scan across a warp and uses
shuffle reduction, similar to standalone quantization.

### Why it was rejected

In this fused kernel, each lane also performs layout-slot decoding, address
mapping, and branch control. Assigning a full warp to one group replicates that
work across 16 lanes. The saved scan iterations do not compensate for the
extra control and address instructions.

The candidate is correct but increased cycles from 23,447,919 to 47,905,399
and instructions from 96,995,644 to 135,503,932. `baseline` remains the
default, while `qparam_warp` is retained for future RTL/configuration studies.

## 7. rope_layout_fused

### Original behavior

Each work item decodes a flattened rotary-pair index into batch, sequence,
head, and pair coordinates. It also selects and computes the output layout for
every pair. Runtime division/modulo and layout control are repeated at a very
fine granularity.

### Selected optimization: `task_chunk16`

One task owns 16 consecutive rotary pairs:

- Decode batch, sequence, and head once.
- Select the row-major or GEMM-W output path once.
- Calculate reusable row and layout bases once.
- Iterate over 16 pairs with incremental offsets.

This is register/address reuse; no LMEM is introduced.

### Result

- Generation row-major: 1,214,806 to 737,174 cycles, 39.3% faster.
- Prefill row-major: 560,571,693 to 304,349,499 cycles, 45.7% faster.
- A fully populated GEMM-W layout shape passes.

The variant selector also changes `VX_CFLAGS`. This is necessary because
changing only `VX_SRCS` can otherwise leave a stale `kernel.elf` in the build
directory.

## 8. head_concat_layout_fused

### Original behavior

The baseline performs flattened-index division/modulo and tiled-address
calculation for every FP16 element.

### Selected optimization: `chunk16_packed`

One task owns a 16-element chunk for one batch, sequence, and head:

- Decode the logical coordinates once.
- Compute input and output tiled bases once.
- Copy eight FP16 pairs with aligned 32-bit transactions.
- Use a scalar tail when a future shape is not pair-aligned.

### Result

For `B=1`, `S=2048`, `H=32`, `D=128`, cycles dropped from 430,014,135 to
34,656,292, a 91.9% reduction.

## 9. eladd_layout_fused

### Original behavior

The baseline maps one work item to one element and calls the GEMM-C tiled
offset calculation for every addition. This repeats row/microtile decoding and
64-bit address arithmetic 32 times per physical microtile.

### Selected optimization: `tile_chunk32`

One task owns one 32-element GEMM-C microtile:

- Decode `(m, k_chunk)` once.
- Calculate the tiled input and row-major input/output bases once.
- Execute the 32 FP16 additions with simple incremental addresses.

### Result

`M=2048`, `K=4096` improved from 305,897,032 to 198,749,359 cycles, a 35.0%
reduction with exact output matching.

## 10. rms_norm_layout_fused

### Original behavior

One row uses a 64-thread block. Threads write partial sums into LMEM and
perform a six-stage tree reduction with a block barrier at every stage. After
the reduction, every thread independently calculates the same square root and
reciprocal.

### Selected optimization: `shuffle_warp`

One 16-thread warp owns one row:

1. Lanes accumulate strided sum-of-squares values in registers.
2. `vx_shfl_down` reduces the values without LMEM or block barriers.
3. Lane 0 computes the reciprocal RMS factor once.
4. `vx_shfl_idx` broadcasts the factor to the warp.
5. Lanes normalize and write the row using the existing fused layout mapping.

Four independent rows can now occupy the four-warp core. The separate
`tile_input_a` comparison in `main.cpp` retains its 64-thread launch.

### Result

The fused `M=2048`, `K=4096` path improved from 264,929,539 to 233,893,271
cycles, an 11.7% reduction. Plain RMSNorm, separate tiling, and fused output
verification all pass. Candidate LMEM usage is zero, versus 256 bytes per
baseline row block.

## 11. elmul_layout_fused

### Original behavior

Both inputs use GEMM-C tiled layout and the output uses GEMM-A tiled layout.
The baseline nevertheless decodes `(m, k)` and calculates three tiled offsets
for every element. The two input offsets are identical, and with the current
32-wide C and A microtiles, the output physical slot order is also identical.

### Selected optimization: `linear_same_layout`

When `log2_mxu_nt == log2_mxu_kt`, the kernel traverses `M_pad * K` physical
slots linearly. It loads both input slots, multiplies them, and writes the same
slot index. Processing zero-filled pad rows is harmless and eliminates all
per-element layout decoding.

A generic decoded fallback remains for future configurations where GEMM-C and
GEMM-A microtile widths differ.

### Result

`M=2048`, `K=11008` improved from 1,155,876,972 to 508,495,338 cycles, a
56.0% reduction. `M=3`, `M_pad=8` also passes.

## 12. silu_layout_fused

### Original behavior

The fused path reads and writes GEMM-C tiled data, but the baseline iterates
logical rows and chunks, rebuilding tiled bases for each chunk. The expensive
SiLU exponential remains necessary, but the layout work is avoidable because
input and output have exactly the same physical order.

### Selected optimization: `linear_tiled`

Only the fused kernel ID uses the new path. It applies SiLU directly to every
physical slot in the `M_pad * K` tiled buffer with a grid-stride loop. Plain
SiLU and row-matched comparison paths retain their previous behavior.

Zero-filled pad rows remain zero after SiLU, so processing them is safe and
simpler than branching around them.

### Result

The fused `M=2048`, `K=11008` path improved from 584,739,293 to 509,626,917
cycles, a 12.8% reduction. The smaller gain than ELMUL is expected because the
hardware exponential dominates SiLU execution. A padded `M=3`, `K=32` shape
also passes.

## 13. detile_output

### Original behavior

The baseline launches one work item per FP16 element and performs one 16-bit
load and one 16-bit store. Adjacent threads calculate adjacent addresses but
cannot amortize task and address overhead.

### Selected optimization: `packed_pair`

One work item handles two adjacent FP16 values:

- Use one aligned 32-bit source load.
- Use one aligned 32-bit destination store when the row address permits it.
- For odd N or an unaligned odd-width row, use one or two 16-bit tail stores.
- Halve the X dimension of the launch.

### Result

`M=2048`, `N=4096` improved from 954,026,773 to 470,857,739 cycles, a 50.6%
reduction. `M=3`, `N=33` validates the odd-width and unaligned-row fallback.

## 14. tile_input_a

### Original behavior

The original optimized implementation already handles two FP16 elements per
thread with a 32-bit load/store and scalar tail handling. It still performs
one full task and tiled-address decode for every pair.

### Selected optimization: `packed4`

The new variant uses the native 64-bit RV64 datapath:

- One task handles four FP16 values.
- Aligned common-case rows use one 64-bit load and one 64-bit store.
- Unaligned source rows or partial K tails are assembled from bounded 16-bit
  loads, avoiding out-of-bounds accesses.
- Pad rows write a zero 64-bit word.
- The X launch dimension is halved relative to `packed2`.

The destination tile offset is always eight-byte aligned because K is padded
to 32 and each task starts at a four-element boundary.

### Result

`M=2048`, `K=4096` improved from 459,805,632 to 225,502,668 cycles, a 51.0%
reduction. `M=3`, `K=35` validates unaligned row starts, a partial K tail, and
pad-row zero filling.

## Cross-Cutting Lessons

### Amortize layout decoding before adding LMEM

The largest layout-kernel gains came from assigning one task to a physical
chunk or traversing an unchanged physical layout linearly. These kernels read
each value once, so LMEM would add traffic and barriers without reuse.

### Use the widest naturally aligned scalar transaction

Paired 32-bit and RV64 64-bit transfers nearly halved cycles in pure layout
copies. Every wide path has an explicit scalar fallback for tails or unaligned
rows.

### LMEM is valuable only with enough reuse

RMSNorm became faster by removing LMEM, while SGEMM's generalized A/B reuse
was still slower because repeated staging and barriers dominated. LMEM should
be justified by measured reuse, not merely by the presence of repeated global
addresses.

### Match launch geometry to warp-level algorithms

Shuffle reductions assume one logical group per warp. A 64-thread launch for
a one-warp softmax row reduced occupancy and obscured the intended execution
model. Host and device variant macros must select geometry together.

### Make variant changes invalidate device builds

Each selector changes both the selected `VX_SRCS` file and a `VX_CFLAGS`
variant tag. This ensures the build flag stamp changes and prevents a stale
`kernel.elf` from being reused after switching variants.

## Related Files

- `STATUS.yaml`: chronological implementation and verification state.
- `../../analysis_workspace/latency_on_hw/vector_kernel_optimization.md`:
  detailed experiment tables and the broader kernel inventory.
