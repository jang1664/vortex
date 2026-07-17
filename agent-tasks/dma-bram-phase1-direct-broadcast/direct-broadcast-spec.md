# Same-Width Direct Data and Broadcast Spec

Status: confirmed

## Goal

Reduce the remaining C4 same-width DMA LUT cost after experiment 007 by
removing redundant per-byte write-data masking and direction-controlled
512-bit destination data muxes.

## Scope

- Modify only the same-width elaboration path in
  `hw/rtl/core/VX_dma_unit_align.sv`.
- Assign the response RAM output directly to destination write data. Partial
  final beats continue to be controlled by byte enable.
- Broadcast the response RAM output to both DCACHE and LMEM request data ports.
  Request valid and read/write control continue to select the active direction.
- Retain the source-response direction mux at the single response RAM write
  port.
- Preserve the unequal-width path unchanged.

## Verification

1. VCS aligned DMA tests at 32:32 and 64:64 byte beats.
2. VCS legacy width-conversion test at 32:16 byte beats.
3. C4 improve xrt-vcs-sim with `fpint_gemm_ffn_hw`, M=N=K=128.
4. C4 DMA OOC synthesis against experiments 007 and 006.

## Expected Effect

- Remove same-width byte-by-byte zero-fill muxes; disabled bytes are don't-care
  because destination byte enable is authoritative.
- Remove runtime direction muxes from the 512-bit destination data buses by
  driving both inactive and active data ports from the same RAM output.
- Do not claim a timing or LUT improvement until the fixed OOC comparison is
  complete.
