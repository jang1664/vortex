# GEMM Parallel Qparam and Prepare/Release Prefetch Specification

Status: confirmed

## Goal

Reduce the steady-state gap between short GEMM input bursts by:

1. loading scale and zero-point data through independent child queues and
   local DMA engines; and
2. hiding pure-load source-read latency behind existing command dependencies
   with a non-architectural prepare phase and a dependency-gated release phase.

The authoritative detailed plan is
`docs/future_optim/gemv/gemm_improve/latency_opt.md`.

## Scope

Expected production RTL scope includes:

- `hw/rtl/VX_gpu_pkg.sv`
- `hw/rtl/core/gemm/VX_gemm_fsm.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl_if.sv`
- `hw/rtl/core/gemm/VX_gemm_node.sv`
- `hw/rtl/core/gemm/VX_gemm_unit_v2.sv`
- `hw/rtl/core/gemm/VX_gemm_unit_v2_if.sv`
- `hw/rtl/core/gemm/VX_lmem_dma_ctrl_if.sv`
- `hw/rtl/core/gemm/VX_lmem_dma_misal.sv`
- `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv`
- `hw/rtl/mem/VX_tmem_subsystem.sv`

Relevant VCS unittests and their Makefile source lists may be updated as needed.
The XRT-VCS application and host layout must remain functionally compatible.

## Confirmed Design Decisions

### Independent scale and zero-point paths

- Split scale and zero-point into distinct opcodes, child queues, completion
  tracking slots, local DMA engines, TMEM switch ports, and GEMM register-write
  ingress paths.
- Do not retain a shared destination arbiter that serializes the two transfers.
- Track physical completion sequences independently as `RID_SC[buf]` and
  `RID_ZP[buf]`.
- Preserve the input command's single logical qparam dependency using
  `RID_SZ[buf] = min(RID_SC[buf], RID_ZP[buf])`, including same-cycle
  completion bypass.
- For QBLK 32 in both QCOL and QROW, each qparam transfer is one 64-byte beat.
- Confirm actual overlap in the presence of TMEM bank arbitration. If the
  existing layout causes an unavoidable conflict, bank coloring is allowed
  only if it preserves the established layout and DMA correctness contracts.

### Prepare/release prefetch

- Existing command waits remain architectural release dependencies.
- Prepare is a non-architectural source read into bounded storage. It must not
  assert consumer valid, write a destination register/TMEM location, update an
  accumulator, publish completion, or publish notify metadata.
- Release occurs only after all original command dependencies are satisfied.
- A prepared command releases its stored transaction instead of starting a
  duplicate DMA. A prefetch miss falls back to the existing normal-start path.
- Prepared state is associated with the exact queued command sequence and is
  invalidated on reset or cancellation.
- Local input, weight, scale, and zero-point loads are prefetchable.
- Tile DMA input, weight, scale, and zero-point loads are prefetchable.
- `OP_O_ACC2LMEM` and `OP_DMA_ST` are never prefetchable.
- Local weight/scale/zero-point source reads wait for tile residency; their
  destination register writes wait for prior-register-use completion.
- Tile DMA source reads may start from immutable DRAM, but TMEM writes wait for
  destination-buffer ownership.

## Constraints and Invariants

- Preserve numerical GEMM behavior for QCOL and QROW.
- Preserve ping-pong register and TMEM buffer ownership.
- Preserve command notify counts, sequence ordering, and quiescence semantics.
- Do not expose prefetched data before release.
- Do not overwrite live weight, scale, zero-point, or TMEM buffers.
- Keep output and psum paths non-prefetchable.
- Use bounded credits; do not require storage for a full maximum-size command.
- If implementation requires a different architectural handshake, dependency
  model, ownership rule, or core datapath concept, stop and report the design
  conflict before proceeding.

## Required Verification

- VCS unittests: `gemm_ctrl`, `lmem_dma_misal`, `gemm_unit_v2`,
  `gemm_tmem_dma_ctrl`, and `gemm_node_improve` with the directed cases listed
  in the authoritative plan.
- XRT-VCS functional matrix with N=256, K=256, QBLK=32, WTRANS=0, WLOAD=8:
  M in {4, 256} crossed with QDIR in {0, 1}.
- GEMM-only FSDB for M=4, QDIR 0 and 1. Confirm parallel qparam activity,
  correct readiness join, prepared input release, and a burst gap below the
  14-cycle baseline.

## Hard Rule

Minor build, Makefile, shell-script, and unittest-testbench repairs are allowed
without interruption when they preserve this specification. Any required
change to the core RTL concept, architectural signals/handshakes, dependency
model, ownership rules, or datapath structure is a blocker that must be
reported before implementation continues.
