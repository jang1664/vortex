# Same-Width Response DPRAM Experiment

| Field | Value |
| --- | --- |
| Experiment ID | `20260717-007-samewidth-response-dpram` |
| Purpose | Replace C4 same-width aligned DMA response FF storage with `VX_dp_ram` |
| Parent design | `20260717-006-c4-aligned-baseline` |
| Baseline design | `20260717-006-c4-aligned-baseline` |
| Config | `configs/improve_th16_tcol32_hwexp_dcache.sh` through alias `C4` |
| Git commit | `502a49dbb52cb78858d481c8cde29728045551b2` |
| Git state | Existing uncommitted OOC infrastructure from baseline 006; see `git_status_before.txt` |
| Vivado | 2025.1, `xcu55c-fsvh2892-2L-e`, `VX_dma_engine_ooc`, 100 MHz |
| Unittest | PASS: VCS 32:32, 64:64, and legacy 32:16 configurations |
| Integration audit | Recorded run used physical XRT, not socket-backed `vortex_xrtsim` |
| OOC synthesis | PASS: 100 MHz constraints met; see `comparison.md` |
| Conclusion | Keep as the Phase 1 candidate; full-design synthesis and P&R remain pending |

## Planned Changes

- Modify `hw/rtl/core/VX_dma_unit_align.sv`.
- Modify `hw/unittest/dma_mem_unit/Makefile`.
- Modify `hw/unittest/dma_mem_unit/tb_VX_dma_mem_unit.sv`.
- Update `docs/future_optim/dma_bram_optimization.md` after measurement to
  record the selected SRAM primitive and Phase 1 status.
- Reuse the existing `hw/rtl/libs/VX_dp_ram.sv` without modifying it.

## Backup

Created before production RTL changes at 2026-07-17 19:08.

| Original | Backup | SHA-256 |
| --- | --- | --- |
| `hw/rtl/core/VX_dma_unit_align.sv` | `before/hw/rtl/core/VX_dma_unit_align.sv` | `aebc7167d11d657d927190fd707a0643685466cc643fb0c9304ab186c383d671` |
| `hw/unittest/dma_mem_unit/Makefile` | `before/hw/unittest/dma_mem_unit/Makefile` | `bc2ef317522c8eaceeb85d09c46d340375d2355659d774c31c467633d27278cd` |
| `hw/unittest/dma_mem_unit/tb_VX_dma_mem_unit.sv` | `before/hw/unittest/dma_mem_unit/tb_VX_dma_mem_unit.sv` | `09a5a85fa781ddb7467bfa95a818fd714742fc21b2e67a01ba5d1d1bf2f347ce` |
| `docs/future_optim/dma_bram_optimization.md` | `before/docs/future_optim/dma_bram_optimization.md` | `b5d203b3e61b7afce2a0b1659df83893c1cfc887c1110de62c14bc10825de039` |

## Result

For the C4 same-width configuration, response payloads now use one
`VX_dp_ram` per DMA channel. Source-read buffers contain control fields only,
the destination write path drains the response RAM directly, and a slot stays
in `SLOT_DRAINING` until the destination request fires. The unequal-width path
retains the original register-based implementation.

Compared with baseline 006 using the same OOC top, config, part, constraint,
Vivado version, and synthesis flow, DMA-engine LUTs fell by 19,953 (36.55%) and
FFs fell by 35,042 (73.64%). The implementation consumed 60 additional
RAMB36-equivalent blocks and improved estimated WNS from +3.853 ns to +4.342
ns. See `comparison.md` for the detailed accounting and verification scope.
