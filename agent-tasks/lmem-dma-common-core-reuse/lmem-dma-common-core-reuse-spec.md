# LMEM DMA Common-Core Reuse Specification

## Goal

Replace the dedicated transfer datapath in `VX_lmem_dma_misal` with a wrapper
around `VX_dma_unit` while preserving the local-DMA control, synchronization,
performance-counter, and transfer contracts for both directions.

The detailed architecture and verification plan is maintained in
`docs/future_optim/lmem_dma_common_core_reuse.md` and is normative for this
task.

## Confirmed Scope

- Add `FIXED_DIR=-1` to `VX_dma_unit`, `VX_dma_unit_align`, and
  `VX_dma_unit_misal`.
- Use one constant-select `active_dir` datapath. Do not add direction-specific
  generate branches in this implementation.
- Keep the existing global-DMA `RD_OUTSTANDING=2` defaults.
- Require a positive power-of-two outstanding depth and sufficient source tag
  value width; do not silently reduce the requested depth.
- Define the shared eight-slot local-DMA contract in `VX_gpu_pkg` and reserve
  at least three `tag.value` bits through the LMEM and GEMM local-DMA paths.
- Convert `VX_lmem_dma_misal` into a local-policy wrapper around `VX_dma_unit`.
- Map external LMEM to the common core's DCache-side endpoint and external GEMM
  to its LMEM-side endpoint.
- Pass `FIXED_DIR=DIR`, `RD_OUTSTANDING=8`, and explicit numeric address/tag
  widths from every production and unittest instantiation.
- Retain `RD_PREFETCH_DEPTH` only for source compatibility. It does not control
  the reused core; eight outstanding beats are the initial read-ahead policy.
- Preserve exact-copy semantics by setting padding to zero.
- Preserve normal GEMM synchronization and bypass wrapper sync under
  `GEMM_NAIVE`.
- Preserve the public local-DMA performance semantics with wrapper-owned
  counters.
- Adopt zero-bound and zero-segment-size no-op completion.
- Update the dedicated unittest source manifest and diagnostics; do not add RTL
  aliases solely for hierarchical testbench references.

## Verification Scope

- Static RTL verification with `python tools/verify_rtl.py`.
- Existing common aligned and misaligned DMA unittests.
- Dedicated `lmem_dma_misal` tests for both directions, alignment combinations,
  partial and multi-segment transfers, response reordering, backpressure,
  zero-size commands, normal sync, and naive sync bypass.
- GEMM-node variants that instantiate all local-DMA channels.
- Configured xrt-vcs-sim GEMM integration after unit tests pass.
- Same-configuration cycle comparison where the repository's configured tools
  expose comparable measurements.

## Provisional Regression Budgets

The user's requirement that performance remain nearly similar is interpreted
as follows for this implementation:

- Representative isolated transfer cycle count: no more than 5% regression.
- Sustained-backpressure or concurrent-local-DMA cycle count: no more than 10%
  regression.
Resource-utilization evaluation is explicitly out of scope because the common
`VX_dma_unit` resource impact was evaluated separately. Timing reported by an
integration build may be retained as context, but it is not an acceptance gate
for this task. The user is the cycle-budget exception owner; any cycle-budget
excess must be reported separately and is not accepted automatically.

## Confirmation

Status: confirmed on 2026-07-18 through the architecture discussion and the
explicit request to implement and test the updated plan.
