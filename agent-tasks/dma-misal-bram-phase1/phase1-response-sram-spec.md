# Misaligned DMA Response SRAM Phase 1 Spec

Status: implemented and extended after measurement

## Goal

Reduce the FF and wide dynamic-mux cost of the misaligned DMA response slots by
moving `slot_data_r` into `VX_dp_ram`, while preserving byte-misaligned copies,
width conversion, padding, partial beats, ordering, and backpressure behavior.

## Scope

- `hw/rtl/core/VX_dma_unit_misal.sv`: response payload storage and its read
  lifecycle.
- `hw/rtl/mem/VX_dma_engine.sv`: forward the configured pack width.
- `hw/syn/xilinx/dut/VX_dma_engine_ooc.sv` and `ci/run_dma_ooc.sh`: permit a
  reproducible C4 misaligned OOC build.
- Existing `hw/unittest/dma_mem_unit_misal` tests are the functional gate.

Destination assembly registers and request-buffer payload splitting are not
part of this phase. They remain independent follow-up experiments.

## Measurement-driven extension

Response SRAM alone reduced FF and improved timing, but increased LUT and BRAM.
The experiment therefore also split request payload storage without changing
the destination assembly algorithm:

- Source reads use the existing depth-4 queues with only address, flags, and
  tag metadata.
- Destination writes use independent 1-entry holding buffers containing the
  completed beat and byte enable.
- A fully direct destination path was tested and rejected because periodic
  write backpressure increased the 64/128 unittest time by 14.6%.
- The 1-entry holding stage reduced that penalty to 4.2% and produced the best
  C4 resource/timing result, so it is the retained implementation.

## Design

- Store one `MAX_BYTES * 8` payload per outstanding response slot in a
  synchronous, read-first `VX_dp_ram` with one registered read output.
- Extend the slot lifecycle to `FREE -> WAIT_RSP -> READY -> DRAINING -> FREE`.
- Issue a RAM read only when the in-order writer needs a `READY` slot and no
  prior slot is being drained.
- Hold the RAM output and its slot metadata while one source response is
  consumed over multiple PACK moves or while the destination is stalled.
- Release the slot only after the final source byte has been consumed.
- Do not reset payload memory and do not add another full-width output register.
- Prevent same-address read/write overlap through slot state and simulation
  assertions.

## Constraints

- DMA descriptor format and outstanding-slot count do not change.
- `MISALIGN_PACK_BYTES` remains the C4-configured value of 16 bytes.
- The default production `VX_dma_engine` remains aligned-only unless a parent
  explicitly enables misalignment.
- Success requires passing both 64:128 and 128:64 direction/width cases with
  misaligned offsets, padding, partial beats, and periodic backpressure.
- The result is retained only if C4 OOC synthesis shows a useful resource
  reduction without a timing failure.
