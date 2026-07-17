# DMA Same-Width Direct-Data-Only Experiment

## Goal

Measure optimization 1 independently from optimization 2. Keep the same-width
response RAM data path direct, but remove the broadcast-induced coupling between
source reads and destination writes.

## Scope

- Modify only `hw/rtl/core/VX_dma_unit_align.sv` production RTL.
- Preserve experiment 008 response-capture padding zero-fill.
- Preserve the shared zero selection for padding-only destination beats.
- Preserve direct same-width RAM output in the destination write assembler.
- Restore direction-specific DCACHE and LMEM request-data selection.
- Remove source-read stall gating from the opposite destination and response
  RAM read issue.
- Leave the unequal-width path unchanged.

## Constraints

- Ready/valid payloads must remain stable under periodic request backpressure.
- Partial and padding-only beats must retain zero-fill behavior.
- Compare with experiments 007 and 008 using the same C4 configuration, test
  matrices, OOC top, FPGA part, and 100 MHz timing constraint.

## Confirmed Specification

Confirmed by the user on 2026-07-17: implement and measure optimization 1 only.
