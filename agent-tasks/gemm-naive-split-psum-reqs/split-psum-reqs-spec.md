# GEMM Naive Split PSUM Request Specification

## Status

Confirmed 2026-07-28.

## Goal

Allow a GEMM partial-sum read and write to reach different local-memory banks
in the same cycle. Remove the unconditional per-port read/write serialization
and reduce the write buffering made necessary by that serialization.

## Scope

- Change the `GEMM_NAIVE` shared-LMEM path so that sixteen PSUM write lanes and
  sixteen PSUM read lanes occupy separate `VX_local_mem` request inputs.
- Configure the target test with 32 local-memory banks and 32 local-memory
  request inputs.
- Suppress the GEMM-unit PSUM read request when a simultaneous PSUM write uses
  the same 16-bank set.
- Reduce the PSUM write queue depth in `VX_gemm_node_naive` from 64 to 4.
- Verify the naive GEMM node/unit path and the target 32-bank configuration.

## Design Decisions

- Request inputs 0 through 15 carry PSUM writes.
- Request inputs 16 through 31 carry PSUM reads.
- For a 128-byte PSUM request split into sixteen 64-bit lanes over 32 banks,
  the outgoing wide-address bit zero selects bank set 0-15 or 16-31.
- If simultaneous read and write requests select the same bank set, write has
  priority and the read request is withheld until a later cycle.
- Conflict gating uses request validity and physical LMEM address bits, not
  downstream `ready` and not the GEMM logical accumulator-bank identifier.
- The existing write queue remains in place with depth four to retain generated
  results across downstream backpressure.

## Constraints and Assumptions

- The target configuration has `LMEM_NUM_PORTS=32` and
  `LMEM_NUM_BANKS=32`.
- `GEMM_PSUM_DATA_SIZE` is 128 bytes and `LSU_WORD_SIZE` is 8 bytes, producing
  sixteen PSUM lanes.
- The split PSUM request configuration dedicates all 32 local-memory request
  inputs to PSUM traffic. Any ordinary CPU, DMA, or GEMM LMEM traffic must be
  routed or arbitrated without increasing `VX_local_mem.NUM_REQS` beyond 32.
- Existing unrelated worktree changes must be preserved.

