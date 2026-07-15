# DMA Address Width Parameterization Spec

## Goal

Remove Synopsys DC ELAB-425 failures caused by reading
`dcache_bus_if.ADDR_WIDTH` or `lmem_bus_if.ADDR_WIDTH` from interface instances
inside `VX_dma_unit_align` and `VX_dma_unit_misal` constant expressions.

## Scope

- `hw/rtl/core/VX_dma_unit_align.sv`
- `hw/rtl/core/VX_dma_unit_misal.sv`
- `hw/rtl/core/VX_dma_unit.sv`
- `hw/rtl/core/VX_dma_node.sv`
- `hw/rtl/mem/VX_dma_engine.sv`
- Existing DMA unit testbench bindings, only where explicit width parameters
  are required to preserve non-default bus-width coverage.

## Design Decisions

- Use module parameters, not global macros. A memory-bus address is word
  addressed, so its width depends on both `MEM_ADDR_WIDTH` and the individual
  interface `DATA_SIZE`; one global address-width macro cannot represent both
  DMA endpoints safely.
- Add `DCACHE_ADDR_WIDTH` and `LMEM_ADDR_WIDTH` beside the existing explicit
  tag-width parameters and forward them through `VX_dma_unit`.
- Replace every address-width type/cast and request-buffer width calculation
  in both backends with those parameters. Do not change protocol or datapath
  behavior.
- Compute widths at parents from their existing data-width parameters and
  `MEM_ADDR_WIDTH`, avoiding all `interface_inst.PARAM` references in DC
  elaboration-sensitive contexts.

## Constraints and Assumptions

- Address widths remain `MEM_ADDR_WIDTH - CLOG2(DATA_SIZE)` as defined by
  `VX_mem_bus_if`.
- Existing TAG width parameterization remains unchanged.
- No new opcode, interface signal, or transaction behavior is introduced.
- Verification must cover both aligned and misaligned DMA backends and the
  requested Synopsys source/elaboration flow.

## Final Agreed Spec

Status: confirmed

The user explicitly requested an RTL fix and asked whether a parameter- or
macro-based solution is possible. The parameter-based design above preserves
per-interface widths and directly follows the existing DC-safe TAG-width
forwarding pattern.
