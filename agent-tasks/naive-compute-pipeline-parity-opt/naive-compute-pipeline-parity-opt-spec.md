# GEMM_NAIVE compute pipeline parity specification

Status: **confirmed** (2026-08-22)

## Goal

Make GEMM_NAIVE and GEMM_IMPROVE use the same arithmetic, elastic
valid/ready backpressure, packet-control, generation/consumer, and final-retire
contracts. Preserve their memory-system distinction:

- NAIVE remains row-major, LMEM-backed, and connected through `VX_dma_node`.
- IMPROVE remains tile-major, TMEM-backed, and connected through the
  multi-channel DMA engine.
- Their FSMs and address-generation equations remain backend-specific.

Both functional and performance comparisons must elaborate
`MXU_WLOAD_NUM=8`; WLOAD4 is diagnostic-only.

## Confirmed implementation scope

The authoritative implementation plan is:

`docs/future_optim/gemv/gemm_naive/naive_compute_pipeline_parity_opt.md`

Execute its phases in order, with a verification checkpoint between phases:

1. Enable and baseline NAIVE WLOAD8 without changing compute/FSM/topology.
2. Extract the IMPROVE internal ACC implementation behind a ready/valid ACC
   interface while retaining cycle behavior.
3. Extract the v2 arithmetic and elastic control into one common compute core.
4. Verify variable-latency ACC response and write backpressure contracts.
5. Implement the NAIVE LMEM ACC adapter while retaining external PSUM/final
   LMEM paths.
6. Integrate the NAIVE packetizer and common core; completion is the actual
   final destination write handshake.
7. Align topology-independent operand-DMA queue/backpressure contracts.
8. Remove the legacy unit from the default NAIVE elaboration and run the full
   WLOAD8 comparison matrix.

## Affected areas

- `hw/rtl/core/gemm/VX_gemm_unit_v2.sv` and its interface
- new common compute-core and ACC-interface/adapter modules under
  `hw/rtl/core/gemm/`
- `hw/rtl/core/gemm/VX_gemm_node_naive.sv`
- NAIVE controller/FSM/synchronization only where required to exchange common
  packet metadata and actual-retire completion
- `hw/rtl/core/gemm/VX_lmem_weight_gather_dma.sv`
- a new explicit NAIVE WLOAD8 config
- focused VCS testbenches and configured-build manifests

## Constraints and assumptions

- Do not change NAIVE row-major address equations, LMEM endpoint/mapping, or
  `VX_dma_node` topology.
- Do not copy the TMEM readiness scheduler into NAIVE.
- Do not add row-major/tile-major address branches to the common core.
- Treat backend-produced addresses as opaque packet metadata and hold them
  stable through stalls.
- Do not silently fall back to WLOAD4.
- Preserve valid/payload/control stability and exact one-admission/one-retire
  accounting.
- Stop for design discussion if any Hard Rule in the authoritative plan is
  encountered.

## Acceptance

The completion criteria, test matrix, performance gates, and Hard Rules are
those in sections 10 through 14 of the authoritative plan. In particular,
both final NAIVE and IMPROVE XRT-VCS runs must prove WLOAD8 in the build
manifest and use the same common compute RTL revision.
