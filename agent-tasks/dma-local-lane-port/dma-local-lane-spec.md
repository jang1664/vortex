# DMA Local Lane Port Spec

## Goal

Port the DMA local-memory bandwidth improvement from `vortex_naive` into the current branch. The current branch connects `VX_dma_node` to local memory through a single `LSU_WORD_SIZE` port, so DMA-to-LMEM traffic uses only lane 0. The target design lets DMA issue one aggregate local-memory beat and scatters it across `NUM_LSU_LANES` local-memory lanes.

## Scope

- Add `hw/rtl/mem/VX_mem_bus_split.sv`.
- Modify `hw/rtl/core/VX_dma_node.sv` so its LMEM side is `lmem_bus_if[NUM_LSU_LANES]`.
- Modify `hw/rtl/core/VX_mem_unit.sv` so DMA participates in the LMEM arbiter on every lane.
- Modify `hw/rtl/core/VX_core.sv` to wire `dma_local_data_if[NUM_LSU_LANES]`.
- Keep `hw/rtl/core/VX_gemm_dma_ctrl_with_dma.sv` source-compatible by adapting its single LMEM port through a one-lane DMA-node instance.

## Non-Goals

- Do not port `vortex_naive` GEMM local-memory data path.
- Do not replace the current TMEM/HBM GEMM node.
- Do not add a softmax unit in this change.

## Confirmed Design

Use the existing core DMA node and local memory, but widen only the DMA-to-LMEM side:

```text
VX_dma_unit_misal
  -> wide LMEM bus (NUM_LSU_LANES * LSU_WORD_SIZE)
  -> VX_mem_bus_split
  -> per-lane LMEM buses
  -> VX_mem_unit per-lane arbiter
  -> VX_local_mem
```

This gives `NUM_LSU_LANES * LSU_WORD_SIZE` bytes per aggregate local-memory beat. For example, an 8-lane, 64-bit configuration moves 64 bytes per DMA LMEM beat.
