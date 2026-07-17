# Same-Width DMA Response DPRAM Spec

Status: confirmed

## Goal

Reduce the LUT and FF cost of the aligned improve DMA used by the C4 alias.
Move same-width source response payloads from slot registers and the wide
`wr_slot_buf` into the existing `VX_dp_ram` implementation while preserving
one destination beat per cycle after pipeline fill.

## Scope

- Modify `hw/rtl/core/VX_dma_unit_align.sv`.
- Reuse `hw/rtl/libs/VX_dp_ram.sv`; do not add a new SRAM module.
- Optimize only the elaboration-time `DCACHE_BYTES == LMEM_BYTES` path.
- Preserve the existing register/window path for unequal bus widths.
- Extend `hw/unittest/dma_mem_unit` so both same-width and the existing
  2:1 width-conversion configuration can be verified.
- Compare against `20260717-006-c4-aligned-baseline` with the same C4 alias,
  OOC wrapper, U55C part, Vivado version, and 100 MHz constraint.

## Design Decisions

- Instantiate `VX_dp_ram` with `DATAW=MAX_BYTES*8`, `SIZE=RD_OUTSTANDING`,
  `OUT_REG=1`, `LUTRAM=0`, and read-first behavior.
- A source response writes one complete same-width beat into its tagged slot.
- A read is issued only for the next ordered `SLOT_READY` entry when the SRAM
  output holding entry is empty or its current destination request fires.
- A slot enters `SLOT_DRAINING` at SRAM read issue and becomes `SLOT_FREE` only
  when its destination request fires.
- Destination backpressure blocks further SRAM reads, keeping SRAM output and
  metadata stable.
- Same-width destination requests bypass the wide request elastic buffer.
  Source reads use a control-only request buffer. Unequal-width requests retain
  the existing wide request buffers in this phase.
- Descriptor completion requires all slots, the SRAM output holding entry, and
  request buffers to be empty.

## Constraints

- Preserve descriptor format, tags, outstanding depth, channel count, and
  external interfaces.
- Do not change the misaligned DMA path.
- Do not start OOC synthesis until relevant unit tests and C4 xrt-vcs-sim pass.
- Do not interpret historical full-design post-route utilization as directly
  comparable with the fixed OOC baseline.

## Verification

1. Same-width aligned unit test in both directions with periodic destination
   backpressure, padding, partial final beats, and consecutive segments.
2. Existing 2:1 aligned width-conversion unit test to prove the legacy path is
   unchanged.
3. C4 improve xrt-vcs-sim blackbox workload.
4. C4 DMA OOC synthesis and resource/timing comparison against experiment 006.
