# Misaligned DMA Aligned Fast-Path Specification

## Goal

Remove unnecessary 16-byte PACK serialization when the current source and
destination positions are naturally aligned to the common DCache/LMEM transfer
width.

## Confirmed Scope

- `hw/rtl/core/VX_dma_unit_misal.sv`
- Directed `dma_mem_unit_misal` regression coverage
- Resource analysis for `DMA_RD_OUTSTANDING_SLOT`; no slot-storage redesign in
  this change

## Design

- Define the fast transfer width as `min(DCACHE_BYTES, LMEM_BYTES)` (64 bytes in
  the target configuration).
- Move one fast-width chunk when the source slot position and destination beat
  position are both fast-width aligned and all remaining byte counts cover the
  full chunk.
- Implement only fixed fast-width chunk selection and insertion. Do not add an
  arbitrary wide byte barrel shifter.
- Retain the existing `MISALIGN_PACK_BYTES` path for misaligned prefixes,
  phase-mismatched transfers, short tails, and partial byte enables.
- Allow aligned padding to use the same fast-width zero-fill movement.
- Preserve slot retirement, destination flush, request buffering, and completion
  behavior.

## Constraints

- Preserve G2L and L2G behavior for unequal DCache and LMEM widths.
- Preserve 3-D stride/bound, padding, byte-enable, and backpressure semantics.
- Keep the response slot between the source response and destination write; the
  optimization is a slot-to-writer fast move, not a combinational bus bypass.
- The final implementation target is the Xilinx Alveo U55C. Outstanding-slot
  storage follow-up should favor resetless distributed RAM or a banked FF/LUTRAM
  organization over a shallow, very wide BRAM/URAM mapping.

## Outstanding-Slot Follow-up

- The target depth-eight array currently stores 8 x 1024 payload bits plus 144
  metadata bits. Reset and command clear behavior, together with asynchronous
  indexed reads, has mapped the payload as registers in existing synthesis
  reports.
- First compare the current array against a resetless, full-word-write array
  marked for distributed RAM. This preserves out-of-order response writes and
  the one-cycle 64-byte fast read without wasting wide BRAM/URAM blocks.
- As a second experiment, store payload in 64-byte banks: eight G2L slots use
  one bank each, while the two supported L2G slots use two banks each. The same
  eight physical banks then cover both directions with 4096 payload bits.
- Do not replace tagged response slots with an ordered FIFO unless the source
  interfaces guarantee response ordering.

## Confirmation

Status: confirmed by the implementation request on 2026-07-16.
