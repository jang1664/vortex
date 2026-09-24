# GEMM Per-Path Prefetch Credit Policy Specification

Status: confirmed

## Goal

Make the pre-release source-read credit independently configurable for GEMM
input, weight, scale, zero-point, and tile-DMA load commands. This allows short
input and weight bursts to fill multiple existing outstanding slots without
increasing the one-beat qparam traffic.

## Confirmed Defaults

| Path | Default pre-release beats |
|---|---:|
| Input local DMA | 4 |
| Weight local DMA | 4 |
| Scale local DMA | 1 |
| Zero-point local DMA | 1 |
| Tile DMA load | 4 per active DMA channel |

## Design

- Add five independent compile-time configuration knobs with the defaults
  above. Keep them visible through the normal `VX_config.vh`/`CONFIGS` flow.
- Encode the selected value in each command's existing
  `prepare.max_beats`; do not add a new handshake or change the command format.
- Input, weight, scale, and zero-point local-DMA commands select their own
  credit in `VX_gemm_fsm`.
- Prefetchable tile `OP_DMA_LD` commands use the tile-DMA credit. Stores and
  output/psum commands remain non-prefetchable.
- A descriptor shorter than its configured credit stops at the descriptor
  end. A credit larger than the physical outstanding-slot count remains
  naturally capped by slot occupancy.
- Preserve exact-command release binding, destination commit gating, request
  ordering, dependency waits, and reset invalidation.

## Scope

- `hw/rtl/VX_config.vh`
- `hw/rtl/VX_gpu_pkg.sv`
- `hw/rtl/core/gemm/VX_gemm_fsm.sv`
- Relevant RTL documentation and VCS unittest testbenches

## Verification

- `gemm_fsm`: confirm each command class encodes the requested independent
  credit and prohibited commands encode no prepare.
- `lmem_dma_misal`: exercise a multi-beat pre-release fill and ordered release
  without early destination visibility or duplicate reads.
- `gemm_tmem_dma_ctrl`: exercise tile-DMA load credit four and retain the
  store/output exclusion.
- `gemm_node_improve`: M=4 QCOL and QROW numerical and prefetch-contract checks.
- XRT-VCS: M={4,256}, QDIR={QCOL,QROW}, QBLK=32.
- M=4 QCOL/QROW FSDB: confirm the four input requests no longer contain the
  one-beat-prefetch bubble and check qparam/weight bank contention.

## Hard Rule

The existing prepare/release architecture, dependency model, destination
ownership, and command binding must not change. If separate credits require a
new architectural handshake or invalidate these correctness invariants, stop
and report before changing the design. Testbench and build-script drift may be
repaired without stopping.
