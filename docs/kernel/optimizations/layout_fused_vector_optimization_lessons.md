# Layout-Fused Vector Kernel Optimization Lessons

## Why KV-cache layout fusion was slow

The main problem was not fusion itself. The fused kernel repeatedly recomputed
information that could be reused.

1. A qparam was shared by several output tiles, but min/max was recomputed for
   every tile.
2. Generation append work scaled with the full cache capacity instead of the
   newly appended position.
3. Small helpers remained as calls in the final ELF, adding argument passing
   and stack-frame overhead inside hot loops.
4. Source and weight tiled offsets were rebuilt from multiplications and
   branches for every element.
5. Common Llama prefill shapes with `source_groups == 1` still used the generic
   divide/remainder path.

## Changes that worked

- Compute qparams once per source quantization group and reuse them at all
  required tiled qparam destinations.
- Use a persistent generation path that processes only the new cache position.
- Apply `always_inline` to small helpers called by the kernel body and confirm
  that helper `jal` instructions disappear from the final ELF.
- Compute the first tiled source and weight address, then advance cursors with
  `+1` and tile-boundary correction.
- Add a `source_groups == 1` fast path that removes divide/remainder.

On the real C4 Llama3 prefill shapes, the final source/weight cursor
implementation reduced K-cache cycles by another 58.6% and V-cache cycles by
another 16.2% relative to the earlier `group1` implementation. Generation
append reached 88,390 cycles for K and 88,485 cycles for V, close to the
80,003-cycle standalone result.

## Important counterexamples

Replacing every power-of-two multiply with an explicit shift is not
automatically beneficial. After forced inlining, the compiler already
optimized many constant operations. Extra runtime branches added for partial
tiles increased both instruction count and cycles in several experiments.

The safer order is:

1. Inline helpers and inspect the final ELF/disassembly.
2. Use dynamic instruction counts and hardware cycles to identify what
   remains.
3. Prefer a cursor or recurrence that removes repeated work over a mechanical
   multiply-to-shift rewrite.
4. Measure layout directions independently; for example, K/WTRANS1 and
   V/WTRANS0 do not benefit equally from the same cursor.

## Instruction count is not enough

C4 generation measurements exposed a second bottleneck class. Several fused
kernels execute approximately the same number of instructions as standalone
but take more cycles because their tiled accesses reduce IPC.

The clearest example is the Llama3 R4 Hadamard generation shape:

| Kernel | Instructions | Cycles | IPC |
| --- | ---: | ---: | ---: |
| standalone Hadamard | 4,018,543 | 615,601 | 6.53 |
| layout-fused Hadamard | 4,435,983 | 2,110,026 | 2.10 |

The fused kernel executes only about 10% more instructions but takes 3.43x as
many cycles. A logical row in an `M_pad=8` tiled buffer advances by 512 bytes
between 32-element column groups. The remaining cost is therefore dominated
by tiled-stride memory stalls, not offset arithmetic.

Chunk-per-thread transformations can make this worse. They hoist address
decoding, but SIMD lanes then walk different tiled chunks and issue strided
requests. A warp/subwarp mapping can preserve the hoist while assigning
adjacent elements to adjacent lanes, but only when the extra participating
lanes do enough useful work.

Real C4 measurements separated the successful and rejected mappings:

| Kernel and shape | Previous cycles | Selected cycles | Result |
| --- | ---: | ---: | --- |
| Hadamard R4, M1 | 2,414,294 | 1,052,823 | adaptive multiwarp, -56.4% |
| RMSNorm, M1/K4096 | 277,738 | 168,608 | adaptive four-warp reduction, -39.3% |
| eladd, M1/K4096 | 301,707 | 288,279 | adaptive warp-coalesced path, -4.5% |
| eladd, M2048/K4096 | 198,749,359 | 182,118,492 | retained chunk path, -8.4% |
| head concat, B1/S1/H32/D128 | 215,615 | 255,006 | subwarp rejected, +18.3% |
| RoPE Q, B1/S1/H32/D128 | 335,824 | 517,542 | subwarp rejected, +54.1% |

Hadamard demonstrated why launch selection must depend on available block
parallelism. Four warps on one row were much faster for R4 M1 and modestly
faster for M2, but slower once four independent rows were available. The
selected `adaptive_multiwarp_row` uses four warps only when
`matrix_count * launched_rows < hardware_warps`; R3, M4, and prefill retain
the original one-warp block.

RMSNorm uses the same principle: M1 and M2 use all four warps for one row,
while M4 and larger shapes keep one warp per row.

The first adaptive eladd implementation inlined both alternative hot loops
into one large function. Although its instruction count changed little, M1
fell from 2.49 to 1.76 IPC and regressed to 418,123 cycles. Marking both hot
paths `noinline` isolated their register allocation and code footprint. M1
then reached 288,279 cycles, while the prefill chunk path also improved to
182,118,492 cycles. Inlining small address helpers is useful, but inlining
whole alternative kernels can be harmful.

The head-concat and RoPE subwarp experiments are useful negative results.
Their existing packed chunk kernels already amortize address decoding over
several adjacent values. Splitting one task across subwarps reduced useful
work per lane and lowered IPC, so both candidates remain selectable for
reference but are not defaults.

## Padding work in generation

`elmul_layout_fused` and `silu_layout_fused` used a linear identical-layout
path over `M_pad * K`. This is efficient for prefill, where `M == M_pad`, but
generation uses `M=1/2/4` with `M_pad=8`, producing 8x/4x/2x excess element
work.

Their selected `linear_skip_pad_rows` variants keep the prefill path unchanged
and map only compact useful elements into physical tiled slots with shifts and
masks.

For ELMUL M1/K14336, C4 cycles fell from 1,281,189 to 425,835, a 66.8%
reduction. M1/M2/M4 fused-to-standalone ratios are now 1.29x/1.35x/1.39x.

For SiLU M1/K14336, cycles fell from 1,427,604 to 528,548, a 63.0%
reduction. The selected fused kernel is faster than standalone for all tested
generation batches: 0.875x/0.828x/0.793x standalone cycles for M1/M2/M4.

Both variants passed M1/M2/M4 K14336 and the non-power-of-two-row fallback
M3/K32 on real C4 hardware.

## Standalone fairness pass

The same optimization checklist was applied to every standalone counterpart.
Fused-only tiled-address correction does not exist in row-major standalone
kernels, so mirroring the source text would add work rather than make the
comparison fair. The transferable transformations were launch adaptation,
loop-invariant index decoding, chunking, packed copies, and reduction
selection.

Four standalone kernels had transferable hot spots and were optimized:

| Kernel and C4 shape | Baseline cycles | Selected cycles | Reduction |
| --- | ---: | ---: | ---: |
| Hadamard R3, rows=8, D=128 | 398,275 | 165,415 | 58.5% |
| Hadamard R3 prefill, rows=8192, D=128 | 339,079,433 | 88,311,573 | 74.0% |
| Hadamard R4, rows=4, D=14336 | 2,247,756 | 2,176,671 | 3.2% |
| RMSNorm, M4/K4096 | 403,017 | 308,525 | 23.4% |
| RMSNorm prefill, M2048/K4096 | 167,940,119 | 118,812,509 | 29.3% |
| head concat, B1/S1/H32/D128 | 186,286 | 133,543 | 28.3% |
| head concat prefill, B1/S2048/H32/D128 | 112,378,174 | 26,128,647 | 76.8% |
| RoPE Q, B1/S1/H32/D128 | 251,643 | 215,186 | 14.5% |
| RoPE Q prefill, B1/S2048/H32/D128 | 286,594,661 | 200,176,017 | 30.2% |

Standalone Hadamard required a more specific adaptive policy than the fused
kernel. A one-warp row is best for the 128-wide R3 transform, and for the four
independent R4 generation rows. The 16384-wide padded R4 prefill transform is
3.7% faster with all four warps per row. The selected `adaptive_row` therefore
uses transform size as well as row count. It keeps the R4 prefill result at
556,483,935 cycles, effectively identical to the 556,482,156-cycle multiwarp
baseline, while retaining the generation and R3 gains.

Standalone RMSNorm now uses the same adaptive reduction as its fused
counterpart: a shared-memory multiwarp reduction when there are fewer rows
than hardware warps, and a shuffle one-warp reduction otherwise. M1 remains
on the original multiwarp path at 157,636 cycles.

Standalone head concat and RoPE had repeated index division in their
per-element or per-pair loops. `chunk16_packed` decodes one B/S/H task per
16-value chunk and copies aligned FP16 pairs with 32-bit operations.
`task_chunk16` decodes one B/S/H/position task per 16 RoPE pairs. Both keep
partial-chunk fallbacks; C4 edge cases with head dimensions 35 and 70 passed.

No source change was appropriate for the remaining counterparts:

- ELMUL and ELADD already use a coalesced linear grid-stride loop over only
  useful elements.
- SiLU already hoists row bases and traverses 32-element chunks.
- standalone KV quantization already uses the selected groupwise qparam reuse
  implementation.
- standalone softmax already uses its separately optimized row/reduction
  implementation; fused tiled-address cursors do not apply to it.

This is the fairness criterion: apply an optimization principle wherever the
same bottleneck exists, not an identical tiled implementation where the
bottleneck is absent.

## Checklist for other kernels

For each remaining `*_layout_fused` kernel, check:

- Is the same statistic, scale, zero point, or mask recomputed for multiple
  output tiles?
- Is a layout offset helper called inside the element loop?
- Are power-of-two tile constants passed as runtime values that prevent
  constant propagation?
- Does a common shape still execute divide/remainder?
- Does a helper remain as a call in the final ELF?
- Can row/column progression use a cursor?
- Do adjacent SIMD lanes access adjacent memory, or did chunking turn the
  access into one tiled stride per lane?
- Does generation process padded rows that are mathematically zero or ignored?
- Did instruction count improve while hardware IPC regressed?

After layout-fused optimization is complete, apply the same inlining,
loop-invariant hoisting, cursor, launch-occupancy, and coalescing analysis to
the corresponding standalone vector kernels for a fair C3/C4 comparison.
Standalone kernels do not need fused-only address correction, so only
techniques that apply to their actual access pattern should be mirrored.
