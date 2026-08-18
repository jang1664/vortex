# Restricted Interleaved HBM–DMA–TMEM Optimization Spec

Status: **confirmed**

## Goal

Decouple TMEM bank count, DMA channel count, and HBM AXI-port count, then support a restricted interleaved topology without a full crossbar. The primary experiment compares the existing `T/D/H=8/8/8` topology with `16/8/8` so TMEM bank-conflict reduction can be measured while DMA and U55C HBM topology remain unchanged.

## Scope

- Add independent `NUM_TMEM_BANKS`, `NUM_DMA_CHANNELS`, and `NUM_HBM_PORTS` parameters and configuration assertions.
- Separate TMEM-bank arrays from DMA-channel arrays through the core/GEMM/TMEM hierarchy.
- Route DMA channel `c` only to TMEM banks `c + k*D`; for `16/8/8`, channel `c` owns banks `{c,c+8}`.
- Preserve logical 64-byte interleaving and load/store round trips.
- Keep U55C HBM remap based on `H=8`, including `0 B -> port0/PC0` and `64 B -> port1/PC4`.
- Keep the current `fpint_gemm` tile-major layout, job register interface, and DMA command meaning.
- Update capacity calculations to use the actual TMEM bank count.
- Add focused tests and run the planned VCS and XRT-VCS matrices.

## Design decisions

- `T`, `D`, and `H` are positive powers of two.
- `D <= min(T,H)` and `PLATFORM_MEMORY_NUM_BANKS % H == 0` are mandatory elaboration-time contracts.
- Logical block mapping is `channel=n%D`, `TMEM bank=n%T`, `HBM port=n%H` for 64-byte block `n`.
- Endpoint ownership is static: `bank%D` and `port%D` select the only DMA channel allowed to reach that endpoint.
- The primary production target is `16/8/8`; HBM-side routing remains the existing direct `D==H` topology in this experiment.
- Generic unequal-topology support and assertions must remain structurally correct, with focused elaboration coverage for `4/2/2` and `8/4/8` where feasible.
- Existing dirty-worktree changes, especially TMEM urgency/ready-ahead work, must be preserved.

## Constraints and assumptions

- No full HBM-to-TMEM crossbar.
- No software tensor repacking.
- No change to U55C physical port-to-PC connectivity for `H=8`.
- Request payload/route stability, response ownership, exact completion, and reset cleanup remain mandatory.
- Verification stops at the first genuine failure and follows the repository configured-build/VCS/XRT-VCS rules.

## Final agreed spec

Implement the complete plan in `docs/future_optim/gemv/gemm_improve/tmem_hbm_interleaved_dma_opt.md`, with `8/8/8` as the compatibility baseline and `16/8/8` as the main TMEM-bank expansion target. Completion requires functional unit/integration/blackbox PASS and an explicit performance comparison between the two configurations.
