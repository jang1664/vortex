# DMA Padding-Optional Direct Data Path Specification

Status: confirmed

## Goal

Reduce the HBM-to-TMEM DMA datapath cost by compiling away padding-specific
zero-fill and byte-mask logic where production descriptors never request
padding. Preserve the existing generic DMA behavior by default.

## Scope

- Add `ENABLE_PADDING`, defaulting to `1`, to `VX_dma_unit_align` and its
  `VX_dma_unit` wrapper.
- Forward the parameter through `VX_dma_engine` and select
  `ENABLE_PADDING=0` only in the production HBM-to-TMEM engine instantiated by
  `VX_tmem_subsystem`.
- Keep `VX_dma_node`, local DMA, the misaligned backend, and existing users on
  the default padding-enabled behavior.
- Extend `VX_dma_engine_ooc` and `ci/run_dma_ooc.sh` with a selectable padding
  mode recorded in the OOC manifest and top-level generic.
- Add focused verification for dual-DUT parity, both transfer directions,
  equal 32-byte and 64-byte bus widths, full and partial final beats,
  out-of-order responses, destination backpressure, and overlapping response
  slots.
- Add negative checks for nonzero padding in disabled mode and unequal bus
  widths in disabled mode.

## Design Decisions

- `ENABLE_PADDING=1` is bit/cycle compatible with the existing implementation.
- `ENABLE_PADDING=0` requires `DCACHE_BYTES == LMEM_BYTES` at elaboration.
- A disabled-mode descriptor must have `PAD==0`; simulation fails immediately
  when such a descriptor is accepted otherwise.
- Disabled mode defines `valid_total` as `seg_size_r`, writes raw response RAM
  data without byte zero-masking, and directly drives request payload data from
  `ram_wr_slot_data`.
- Every non-empty disabled-mode destination write consumes a ready response
  slot. The final partial beat is protected only by the existing `byteen`.
- Disabled mode treats request data on reads, inactive directions, and invalid
  cycles as don't-care.
- No fixed 64-byte assumption is introduced; all sizing uses interface-derived
  byte counts.

## Constraints and Success Criteria

- Padding-enabled results remain unchanged, including zero-fill for partial
  padding and padding-only destination beats.
- With `PAD=0`, disabled mode matches enabled mode for valid/rw/address/byteen,
  accepted write data, and completion cycle.
- OOC synthesis uses the same bigmem W8 TH16/U55C/Vivado settings for both
  modes. Keep the production opt-in only if optimized LUT usage decreases and
  BRAM/DSP usage does not increase.
- M4 blackbox and full XRT implementation are outside this task.
