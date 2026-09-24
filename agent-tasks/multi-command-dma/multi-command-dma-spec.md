# Multi-Command HBM Tile DMA Specification

Status: confirmed
Source of truth: `docs/future_optim/gemv/gemm_improve/multi_cmd_dma.md`

## Goal

Allow the next tile's input loads and compute to overlap a preceding output
store by scheduling multiple logical commands in the HBM tile DMA path.

## Scope

- Add an eight-entry DMA child FIFO and eight tagged inflight slots to
  `VX_gemm_ctrl`.
- Add DMA-only command and completion tag sidebands to the GEMM DMA interface.
- Add a parameterized pending queue (default depth four), global priority
  scheduler, one paused store context, full-descriptor capture, and registered
  output-store chunk generation to `VX_gemm_tmem_dma_ctrl`.
- Add `dma_priority` and `dma_max_chunk_log2p1` command fields and populate them
  in `VX_gemm_fsm`.
- Preserve `VX_dma_engine`, `VX_dma_unit`, and all local-DMA behavior.
- Extend directed unit verification and run xrt-vcs blackbox performance and
  numerical comparisons for 4/8/16/32 beat-per-channel store chunks.

## Confirmed Design Decisions

- DMA command acceptance uses `cmd_valid && cmd_ready`; command and tag remain
  stable under backpressure. `idle` only denotes a fully drained path.
- The controller assigns one of eight three-bit tags and applies a tagged
  completion only to that slot's notify/RID metadata. A slot released by a
  completion cannot be reallocated in the same cycle.
- Input loads have high priority and stores have low priority. Ordering is FIFO
  within each priority. Only a fully completed store chunk is a preemption
  boundary; a selected load runs to logical completion.
- Only chunkable output stores are split. A store is chunkable only when all
  eight channels are active and have matching burst-form bounds and total beat
  counts. Fallback or mixed-channel stores retain their captured per-channel
  full descriptors and execute once without preemption.
- `dma_max_chunk_log2p1 == 0` means no scheduler chunk limit; positive values
  encode `1 << (value - 1)` beats per channel. The limit applies only to
  chunkable stores.
- A store chunk preserves `SEG_SIZE`, `ST0`, `ST2`, and `BND2`; derives chunk
  `BND0`, `BND1`, `ST1`, and bases from the flattened per-bank beat cursor; and
  must cover exactly the original descriptor's address set.
- Only the final store chunk generates logical `done`, `done_tag`, and
  `store_done`.
- The initial store chunk parameter is eight beats per channel, subject to the
  required 4/8/16/32 performance comparison and final documented selection.

## Constraints and Assumptions

- HBM/TMEM channel-slot alignment must always hold. Equal per-channel transfer
  lengths, burst-mode descriptors, power-of-two `orig_bnd2`, and
  `max_chunk_beats >= orig_bnd2` are required only for stores classified as
  chunkable.
- Non-chunkable stores must preserve every captured active bit and descriptor
  field exactly, and high-priority commands may arbitrate only after that full
  descriptor drains.
- Chunking must preserve AXI burst and 4 KiB boundary legality.
- Pending depth four excludes the active/paused store context.
- No aging is required; finite high-priority bundles and final drain guarantee
  store forward progress.
- Every hard-rule stop condition and recovery rule in the source document is
  part of this confirmed specification.

## Final Agreed Specification

Confirmed. The complete normative requirements, equations, hard-rule stop
conditions, implementation phases, and seventeen-item verification plan are in
the source-of-truth document named above. This file records the RTL-improvement
workflow's confirmation without duplicating or weakening those requirements.
