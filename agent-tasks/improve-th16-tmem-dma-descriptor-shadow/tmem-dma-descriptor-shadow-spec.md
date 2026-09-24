# TMEM DMA Descriptor Shadow Specification

Status: **confirmed**

## Goal

Reduce placement/routing congestion in `VX_gemm_tmem_dma_ctrl` by removing
candidate-indexed, per-channel expanded descriptor storage and replacing it
with compact candidate ownership plus exactly one decoded next-command shadow.

## Scope

- Primary production RTL: `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv`
- Focused verification: `hw/unittest/gemm_tmem_dma_ctrl`
- Integration verification: `hw/unittest/gemm_node_improve`
- Blackbox configuration: IMPROVE, TH16, WLOAD8, TMEM16, DMA8, HBM8
- Physical comparison: fresh Vivado synthesis and loop/congestion reports

The existing timing-loop fixes in `VX_dma_unit_align.sv`,
`VX_gemm_tmem_dma_ctrl.sv`, and `VX_gemm_node.sv` are the baseline and must be
preserved.

## Confirmed Design

1. Keep the pending FIFO and high/fallback candidates in compact command/tag,
   priority, store cursor, remaining count, and prepare-lifecycle form.
2. Remove `candidate_desc_q[2][NUM_CHANNELS]` and
   `candidate_store_desc_q[2][NUM_CHANNELS]` from the final production design.
3. Maintain exactly one decoded `shadow_desc_q[NUM_CHANNELS]` with an explicit
   compact owner, candidate ID/generation, prepare acceptance, and result state.
4. Build the shadow before the active command completes. A prepared,
   authoritative shadow may chain directly to the active command on the same
   edge with no added state or bubble.
5. High priority always outranks fallback. A fallback shadow is invalidated
   when a high candidate becomes visible, unless its current prepare lifecycle
   must first be safely quiesced.
6. Store continuation is reconstructed from compact store command/cursor state
   into the same single shadow; no second expanded descriptor copy is allowed.
7. Chaining `valid` and `ACTIVATE` remain source-owned and independent of
   `ready`; all active channels must accept atomically. No per-channel fence is
   added.
8. If the authoritative shadow is not ready, use the ordinary issue path; do
   not chain stale state or violate priority to preserve performance.

## Constraints

- No TMEM topology, bank count, DMA channel count, HBM port count, descriptor
  format, address mapping, payload path, or completion-order change.
- No combinational ready-to-valid/ACTIVATE feedback.
- No partial active-channel chaining.
- No extra cycle when the correct shadow is prepared and all channels are
  ready.
- Preserve sticky completion for channels that finish before the last channel.
- Reset must leave no shadow/prepare state without a valid compact owner.
- QBLK16 is outside this task; comparison workload uses QBLK32.

## Acceptance

- Focused VCS and deterministic TH16/TMEM16 node QCOL/QROW tests pass with
  exact functional, ownership, and count contracts.
- M4 XRT-VCS performance remains within 2% of 599 cycles QCOL and 603 cycles
  QROW; an out-of-band result is repeated with the same binary and judged by
  the median. Improvements greater than 2% are allowed when repeatable.
- Input/Weight/Output traffic remains exact and numerical results pass.
- Candidate-expanded descriptor arrays are absent and exactly one next-command
  decoded shadow remains.
- Vivado reports zero TIMING-23, LUTLP-1, and combinational loops, and the
  descriptor-control routing/fanout pressure is reduced without a replacement
  hotspot.

The detailed implementation and verification sequence is defined in
`plan.md` and is authoritative where this specification does not add detail.

## Physical Acceptance Result

Fresh exact-config synthesis and post-init analysis confirm that the candidate
descriptor arrays are absent, one decoded shadow remains, descriptor-control
area/fanout is substantially lower, and the prior `TIMING-23` loops are absent.
In the exact U55C placement, `u_tmem_dma_ctrl` dropped from 20 congestion-report
appearances to one level-5 appearance, but the design still reached congestion
level 7 in broad TMEM-switch, stream-queue, compute, and HBM regions. Thus the
descriptor-shadow design is functionally and structurally verified, while the
specification's whole-design no-replacement-hotspot acceptance condition is not
met. Further congestion work is out of scope and requires a new plan.
