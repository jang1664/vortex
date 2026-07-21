# Generalized Misaligned DMA Datapath Specification

Status: confirmed

## Goal

Replace the wide dynamic byte-insertion datapath in `VX_dma_unit_misal` with generated lane aligners and fixed-ratio gearboxes so aggregate Dcache and LMEM widths from 64B through 512B are supported without reducing steady-state payload bandwidth.

## Scope

- Parameterize the node-backend DMA OOC flow and capture matched old-RTL baselines.
- Add reusable fixed-ratio gearbox and lane-aligner RTL with focused VCS unit tests.
- Integrate the generated datapath into `hw/rtl/core/VX_dma_unit_misal.sv` while preserving tagged response storage, ordering, outstanding depth, descriptor behavior, and write holding.
- Verify runtime direction, both `FIXED_DIR` elaborations, aggregate splitter masking, padding, backpressure, response reordering, and the configured width matrix.
- Compare 64B/256B and 512B/512B candidates with matched Vivado OOC synthesis.

## Design Decisions

- Use generated 64B-or-smaller canonical lanes and parallel lanes for wider aggregate bandwidth.
- Use elaboration-time same-width, narrow-to-wide, and wide-to-narrow gearbox branches.
- Preserve full `min(DCACHE_BYTES, LMEM_BYTES)` bytes/cycle steady-state throughput.
- Preserve response SRAM and the one-entry destination write-holding boundary.
- Keep a temporary legacy comparison path until functional, throughput, integration, and OOC gates pass.
- Remove the legacy path only after adoption, then rerun the final regression and required OOC rows.

## Constraints and Assumptions

- Do not modify MXU RTL or memory topology to recover area.
- Do not modify the user's existing changes in `configs/` or `hw/rtl/core/VX_dma_unit_align.sv`.
- Keep `RD_OUTSTANDING=8` and existing external descriptor/interfaces unchanged.
- Qualified aggregate widths are 64B, 128B, 256B, and 512B with ratios no greater than 8:1.
- OOC comparisons must use identical top, widths, config, part, Vivado version, XDC, defines, source closure, parameters, and synthesis options.
- Full FPGA PnR is a follow-up qualification after the OOC-qualified candidate is complete.

## Final Agreed Specification

The implementation authority is `docs/plans/2026-07-20-001-refactor-generalized-misaligned-dma-plan.md`. Complete U1 through U8 in dependency order, satisfy R1 through R17 and AE1 through AE6, and record every verification iteration in `STATUS.yaml`.

