# 05 — DMA engine slimming

## Target

- `hw/rtl/mem/VX_dma_engine.sv` and its children
  (`g_channel[0..7].u_dma_unit` = `VX_dma_unit_misal__parameterized0_*`)
- `hw/rtl/core/VX_dma_unit_misal.sv` (module source — same module
  reused with different parameters)

## Problem

`u_dma_engine` consumes **389,836 LUT** (34 % of vortex_afu), of which
**8 channels × 43,953 LUT ≈ 351 k** are the DMA units themselves.

Per-channel footprint is driven by:
- `slot_data_r [8][512b]` — 8 outstanding response slots (4,096 flop)
- `win_lmem [1024 b]` + `win_dcache [1024 b]` — 2-beat window buffers
  for misaligned transfers (2,048 flop)
- `tmp_win >> (src_bytes * 8)` — **1,024-bit variable-byte barrel
  shifter**, combinational, replicated per direction (L2G and G2L).
  This alone is estimated at ~15 k LUT per channel.
- per-byte mask generation loops (`mask_dcache_range`,
  `mask_lmem_range`)
- 3D index arithmetic, stride-bound precalculation, and six pipelined
  `VX_mul_u32_pipe` multipliers

## Change (menu, pick to taste)

1. **Shrink WIN_BYTES from 2 × MAX_BYTES to 1 × MAX_BYTES.**
   Halves the barrel shifter and halves `slot_data_r` width. Requires
   the control FSM to stall for one-beat windows but avoids mid-beat
   buffering.
2. **Reduce `RD_OUTSTANDING_CAP` from 8 to 4 (or 2).**
   Linear reduction in `slot_data_r` (8 × 512 = 4 k flop → 4 × 512 =
   2 k flop), plus proportional slot-state / mux logic.
3. **Drop byte-misaligned support on the GEMM-side channels** — they
   mostly touch HBM/tensor-mem which are 64-byte aligned anyway.
   Replace `VX_dma_unit_misal__parameterized0_*` with a simpler aligned
   DMA unit (`VX_dma_unit_aligned`) when both endpoints are word
   aligned, keeping `misal` only for the host-side CPU DMA node
   (the singleton 36,397-LUT instance).
4. **Sequentialize the barrel shifter** — replace the combinational
   `>> (src_bytes * 8)` with a 1-bit (or 1-byte) shift register over
   N cycles. Saves LUTs at the cost of throughput per beat.

## Expected savings

- (1) alone: ~20 k / channel × 8 = **160 k LUT**
- (2) alone: ~5 k / channel × 8 = **40 k LUT**
- (3) alone for the 8 GEMM-side channels: could drop each to ~15 k
  LUT → saves **200+ k LUT**, depending on the aligned replacement.

Combine (1)+(2) before committing to (3) to see whether alignment
assumption holds.

## Risks

- `(3)` assumes all HBM accesses through the GEMM DMA channels are
  aligned. Audit `VX_gemm_dma_ctrl` to confirm — if any path uses
  sub-beat bases, (3) breaks correctness.
- Shrinking windows may increase throughput loss on small transfers
  or on sources with bursty latency.
- Slot reduction reduces tolerance for cache-miss latency — measure
  before/after on representative workloads.

## Verification

- `hw/unittest/dma*`, `lmem_dma_misal`, `dma_mem_unit*`
- End-to-end GEMM with non-multiple-of-64 bound (stresses misaligned
  path) to confirm any retained misal behavior still works.
