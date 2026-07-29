# can_coalesce_dim0 Descriptor Pipeline Spec

## Goal

Break the routed 100 MHz critical path from `VX_gemm_dma_ctrl_naive/cmd_q`
through the `coalesced_seg_size` multiplier and descriptor packing into the
job-frontend DMA request, while preserving descriptor contents and handshake
behavior.

## Scope

- Modify `hw/rtl/core/gemm/VX_gemm_dma_ctrl_naive.sv` only.
- Register the fully decoded DMA descriptor before `S_PROG_W` consumes it.
- Keep command capture, allocation, notification, kick, and polling protocols
  unchanged.

## Design decisions

- Snapshot all descriptor fields that feed `prog_w_data`, not only
  `can_coalesce_dim0`, so one descriptor cannot mix registered and live decode
  values.
- Capture the snapshot after command decode and before descriptor programming.
- Make `S_PROG_W` consume only snapshot registers. This places a sequential
  boundary between the 64-bit coalescing calculation and `dma_if.req_data`.
- Preserve the current coalescing predicate and arithmetic exactly.
- Do not add a throughput bubble beyond states already required by the
  allocation transaction unless structurally necessary.

## Constraints and assumptions

- The command remains stable in `cmd_q` from acceptance until the operation
  completes.
- Descriptor programming begins only after allocation succeeds, leaving time
  to capture the decoded descriptor independently of the MMIO write path.
- Reset values must be deterministic.
- Existing unrelated worktree changes must not be modified.

## Final agreed spec

**Confirmed from the user's request on 2026-07-29.** Implement a registered
descriptor snapshot that removes the live `can_coalesce_dim0` combinational
cone from `S_PROG_W`, then run focused deterministic RTL verification.
