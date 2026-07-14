# FPINT GEMM Multi-Core Support Specification

**Status**: confirmed

## Goal

Enable disjoint M/N output partitioning across Vortex cores for both the improve
(tiled) and naive (row-major) FPINT GEMM implementations, then verify the same
descriptor contract in RTL simulation and simx.

## Scope

- Activate the existing partition helper in the improve regression kernel.
- Correct the improve RTL output DMA address for nonzero partition starts.
- Add nonzero-start descriptor coverage to improve and naive RTL testbenches.
- Add naive row-major descriptor addressing to the simx GEMM node.
- Extend `ci/run_black.sh` with reproducible simx and core-count options.
- Verify one-core compatibility and four-core exact, partial, inactive, QDIR,
  and WTRANS cases.

## Design Decisions

- Partition only the M/N output grid; every active core consumes the full K.
- Reuse the existing 128 x 128 tile-grid partition algorithm.
- Preserve the existing descriptor MMIO register numbers and semantics.
- Keep core 0 as the only host status reporter.
- Keep checked-in config scripts at `NUM_CORES=1`; use runtime/build overrides
  for four-core verification.
- Select improve versus naive simx layouts at compile time with `GEMM_NAIVE`.
- Do not add hardware, synthesis, FPGA image, or K-reduction work.

## RTL Contract

For an active descriptor, `orig_M/N/K` describe the global matrices while
`target_M/N/K` and `m_start/n_start` describe the core-local rectangle. Improve
output DMA addresses use global tile coordinates:

```text
global_mt     = mt_base_q + mt_cur
global_nt_mxu = (nt_base_q + nt_cur) * dma_nt_mxu_dim + o_nt_mxu_q
```

These coordinates select the final output slot without changing the existing
partial-M-dependent output stride.

## Constraints

- Follow the address-layout definitions in
  `agent-tasks/port-scale/fpint-gemm-spec.md`.
- Preserve flat software addresses at simulator memory interfaces as documented
  by `docs/hbm-bank-interleaving.md`.
- Rebuild the VCS simulator after RTL changes because its Makefile does not track
  RTL dependencies.
- Run blackbox tests through `ci/run_black.sh` from a configured build directory.

## Final Agreed Specification

The implementation-ready work breakdown, test matrix, failure diagnosis order,
and definition of done are recorded in `PLAN.md`. This specification is
confirmed for implementation on `feat/gemm-multicore-support`.
