# Same-Width Direct-Data-Only Experiment

| Field | Value |
| --- | --- |
| Experiment ID | `20260717-009-samewidth-direct-only` |
| Purpose | Isolate same-width direct RAM write-data optimization |
| Parent design | `20260717-008-samewidth-direct-broadcast` |
| Comparison design | `20260717-007-samewidth-response-dpram` |
| Fixed baseline | `20260717-006-c4-aligned-baseline` |
| Config | `configs/improve_th16_tcol32_hwexp_dcache.sh` through alias `C4` |
| Git commit | `502a49dbb52cb78858d481c8cde29728045551b2` |
| Unittest | PASS: VCS 32:32, 64:64, and legacy 32:16 |
| xrt-vcs-sim | PASS: socket-backed `vortex_xrtsim`, M=N=K=128 |
| OOC synthesis | PASS: 28,922 LUT, 12,522 FF, WNS +4.495 ns |
| Conclusion | Preferred over 007 and 008 |

## Planned Change

- Keep response-capture padding masking and direct same-width RAM data.
- Restore direction-specific DCACHE/LMEM request data.
- Remove cross-direction stall coupling introduced by output broadcast.
- Keep unequal-width behavior unchanged.

## Backup

Created before experiment 009 RTL changes at 2026-07-17 22:52.

| Original | Backup | SHA-256 |
| --- | --- | --- |
| `hw/rtl/core/VX_dma_unit_align.sv` | `before/hw/rtl/core/VX_dma_unit_align.sv` | `84e3fcfd496f766de561fe9ac16f14fa954b3d3f2b1d1545790a3d1d06889ccc` |

## Result

Relative to experiment 007, direct-only removes 5,713 LUTs (16.49%), removes
22 FFs, leaves BRAM and DSP counts unchanged, and improves WNS by 0.153 ns.
Periodic-backpressure completion times exactly match 007 and recover the loss
measured in experiment 008. See `comparison.md` for the full result.
