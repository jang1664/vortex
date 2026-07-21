# Back-to-back improve-GEMM descriptor support

Status: confirmed

## Goal

Allow two different improve-GEMM descriptors to execute sequentially in one
Vortex kernel. This is required for the C4 attention schedule:

1. QK GEMM and progress-driven online softmax
2. worker join and core fence
3. PV GEMM

The design does not execute QK and PV GEMMs concurrently.

## Confirmed failure

The first QK descriptor and a standalone PV descriptor are individually
correct on C4. A back-to-back PV descriptor consumes stale or uninitialized
local state. `VX_gemm_sync` retains completion values across `OP_CLEAR`, so the
second descriptor's WAIT commands can pass on the first descriptor's values
before its own DMA/LDMA notifications arrive.

## Scope

- Clear improve-GEMM synchronization registers when an accepted `OP_CLEAR`
  completes a descriptor.
- Extend `hw/unittest/gemm_node_improve` with two different descriptors issued
  without a reset between them.
- Keep descriptor execution strictly sequential.
- Keep the existing MMIO ABI unchanged.

## Constraints

- A core `fence` only publishes softmax stores; it cannot reset accelerator
  synchronization state.
- The current C4 bitstream cannot contain this RTL change. Actual FPGA
  verification requires rebuilding the C4 image after RTL verification.
- The test must use different input/weight/output buffers so stale-state reuse
  cannot pass accidentally.

## Final design

On `clear_fire = in_valid && is_clear && can_accept`, `VX_gemm_sync` sets every
sync register to zero with priority over child updates. The existing job done
handshake remains on the same accepted CLEAR command. A regression issues QK-
and PV-shaped GEMMs back-to-back without `apply_reset()` and checks both output
buffers.
