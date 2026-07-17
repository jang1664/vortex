# Same-Width Direct Data and Broadcast Experiment

| Field | Value |
| --- | --- |
| Experiment ID | `20260717-008-samewidth-direct-broadcast` |
| Purpose | Remove same-width per-byte data masking and destination direction muxes |
| Parent design | `20260717-007-samewidth-response-dpram` |
| Fixed baseline | `20260717-006-c4-aligned-baseline` |
| Config | `configs/improve_th16_tcol32_hwexp_dcache.sh` through alias `C4` |
| Git commit | `502a49dbb52cb78858d481c8cde29728045551b2` |
| Unittest | PASS: VCS 32:32, 64:64, and legacy 32:16 configurations |
| Integration audit | Recorded run used physical XRT, not socket-backed `vortex_xrtsim` |
| OOC synthesis | PASS: 27,259 LUT, 12,560 FF, WNS +4.721 ns |
| Conclusion | Combined variant reduces LUT but needs item-1-only isolation before acceptance |

## Planned Change

- Modify `hw/rtl/core/VX_dma_unit_align.sv` only.
- In `SAME_WIDTH_FAST`, use the response RAM output directly as write data.
- Broadcast that data to DCACHE and LMEM request data ports while keeping
  request control direction-selective.

## Backup

Created before experiment 008 RTL changes at 2026-07-17 19:59.

| Original | Backup | SHA-256 |
| --- | --- | --- |
| `hw/rtl/core/VX_dma_unit_align.sv` | `before/hw/rtl/core/VX_dma_unit_align.sv` | `819d48d8db1db173e17533fb312e2014fea3ad0b4c4b3b9d183b8e2aa9ea8550` |

## Initial Git State

Experiment 007 and its OOC infrastructure are uncommitted in the working tree.
This experiment is layered on that verified state; no unrelated tracked files
will be modified.

## Result

Relative to experiment 007, the combined change removes 7,376 LUTs (21.30%),
adds 16 FFs, leaves BRAM and DSP counts unchanged, and improves estimated WNS
by 0.379 ns. The recorded integration runs used physical XRT and do not provide
a controlled VCS-backend cycle comparison. Periodic-backpressure unit suites
take 7.6-9.9% longer because the broadcast stability rule couples source-read
stalls to destination progress. See `comparison.md` for the complete result and
decision.
