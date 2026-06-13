# Aligned DMA Width Converter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Goal

Replace the expensive aligned-mode byte-window behavior in `hw/rtl/core/VX_dma_unit_misal.sv` with a direction-symmetric width converter that handles `LMEM_BYTES != DCACHE_BYTES` without wide variable shifts, dynamic data clears, or tail-drop queue surgery.

Correctness requirements:

- `L2G`: source is local memory, destination is dcache/global.
- `G2L`: source is dcache/global, destination is local memory.
- Either bus can be wider or narrower than the other.
- `ENABLE_MISALIGN=1` keeps the existing generic misaligned byte-window behavior.
- `ENABLE_MISALIGN=0` supports aligned descriptors only, including unequal source and destination widths.
- Padding semantics remain unchanged: copy `valid_total = seg_size - padding` bytes, then write zero padding bytes up to `seg_size` using destination byte enables.
- Stale data in unused lanes is ignored by `byteen`; do not clear wide data registers just to prevent stale bits.

## Architecture

The aligned implementation should be modeled as:

```text
selected source bus -> source response slots -> chunk stream -> selected destination bus
```

Direction selects the source and destination:

```text
direction_bit_r == 1'b1: L2G, src=LMEM,   dst=DCACHE
direction_bit_r == 1'b0: G2L, src=DCACHE, dst=LMEM
```

Keep the existing read/write FSM, response slot ordering, segment counters, and `done_if` behavior. Replace only the `ENABLE_MISALIGN=0` staging/consume logic. The current `win_lmem`, `win_dcache`, `tmp_win >> (src_bytes * 8)`, `tmp_win[tmp_valid*8 +: ...]`, and aligned-mode `tail_drop` behavior are the logic that created the large routed `win_dcache[...]` structures in the failed XRT build.

Use fixed compile-time chunking:

```systemverilog
localparam int ALIGNED_SRC_BYTES_L2G = LMEM_BYTES;
localparam int ALIGNED_DST_BYTES_L2G = DCACHE_BYTES;
localparam int ALIGNED_SRC_BYTES_G2L = DCACHE_BYTES;
localparam int ALIGNED_DST_BYTES_G2L = LMEM_BYTES;
localparam int CHUNK_BYTES = (DCACHE_BYTES < LMEM_BYTES) ? DCACHE_BYTES : LMEM_BYTES;
```

Require one width to divide the other in aligned mode:

```systemverilog
initial begin
  if (!ENABLE_MISALIGN) begin
    if (!((DCACHE_BYTES % LMEM_BYTES) == 0 || (LMEM_BYTES % DCACHE_BYTES) == 0))
      $fatal(1, "aligned DMA requires divisible dcache/lmem bus widths");
  end
end
```

That keeps every transfer as fixed chunk slices and small counters. It avoids a general byte barrel shifter.

## Tech Stack

- SystemVerilog RTL: `hw/rtl/core/VX_dma_unit_misal.sv`
- Existing DMA wrapper: `hw/rtl/core/VX_dma_node.sv`
- Existing tests:
  - `hw/unittest/dma_mem_unit/tb_VX_dma_mem_unit.sv`
  - `hw/unittest/dma_mem_unit_misal/tb_VX_dma_mem_unit_misal.sv`
  - `hw/unittest/dma_node/tb_VX_dma_node.sv`
- Build-side tests under `build/hw/unittest/...`
- XRT FPGA synthesis under `build/hw/syn/xilinx/xrt`

## Files

- `hw/rtl/core/VX_dma_unit_misal.sv`: main implementation.
- `hw/unittest/dma_mem_unit/tb_VX_dma_mem_unit.sv`: aligned correctness test, parameterize bus widths and add opposite-width run.
- `hw/unittest/dma_mem_unit_misal/tb_VX_dma_mem_unit_misal.sv`: regression for `ENABLE_MISALIGN=1`.
- `hw/unittest/dma_node/tb_VX_dma_node.sv`: node-level regression with dcache/local arbitration and background traffic.
- Optional: `docs/rtl/core/dma_aligned_width_converter.md` if a design note is wanted after implementation.

## Implementation Tasks

- [x] Add aligned-width localparams and assertions in `VX_dma_unit_misal.sv`.

  Add `MIN_BYTES`, `MAX_BYTES`, `CHUNK_BYTES`, and ratio constants near the existing `DCACHE_BYTES`/`LMEM_BYTES` definitions. Keep these elaboration-time constants. Add an `initial` fatal for non-divisible widths when `ENABLE_MISALIGN=0`.

- [x] Add source-valid metadata to response slots.

  Add a small per-slot metadata array:

  ```systemverilog
  logic [WIN_VALID_W-1:0] slot_valid_bytes_r [RD_OUTSTANDING];
  ```

  On source read issue, compute how many bytes in that source beat belong to the logical segment:

  ```text
  src_beat_off = current_src_read_ptr - rd_base_src_seg_r
  slot_valid_bytes = min(valid_total - src_beat_off, SRC_BYTES)
  ```

  Clamp to zero when `src_beat_off >= valid_total`. Store this with the same `rd_issue_slot_r` used for the tag. This is the key replacement for aligned-mode `tail_drop`: extra rounded-up source bytes never become valid stream bytes.

- [x] Keep the misaligned path intact.

  Guard existing byte-window/drop logic under `if (ENABLE_MISALIGN)`. Do not rewrite the generic path in this change. It already needs variable byte shifts by definition, and changing it increases risk without helping the thread-32 aligned build.

- [x] Implement aligned L2G as fixed chunk conversion.

  For `direction_bit_r == 1'b1`, source is `slot_data_r[*][LMEM_BYTES*8-1:0]`, destination is `dcache_bus_if`.

  Cases:

  - `LMEM_BYTES == DCACHE_BYTES`: direct pass-through, preserving the old same-cycle pull/drain fast path.
  - `LMEM_BYTES > DCACHE_BYTES`: one LMEM source beat is drained through multiple DCACHE writes using a small chunk index.
  - `LMEM_BYTES < DCACHE_BYTES`: multiple LMEM source beats fill one DCACHE destination beat using a destination lane-valid mask.

  Use fixed part-selects like `chunk_idx * CHUNK_BYTES * 8`, where `chunk_idx` is a small counter. Do not shift the whole window.

- [x] Implement aligned G2L with the same source/destination abstraction.

  For `direction_bit_r == 1'b0`, source is `slot_data_r[*][DCACHE_BYTES*8-1:0]`, destination is `lmem_bus_if`.

  The logic should be structurally parallel to L2G, but with the source/destination widths swapped. Avoid naming or comments that imply dcache is always source or local memory is always destination.

- [x] Generate destination write data and byte enables from `out_off`, not from cleared state.

  For every destination write:

  ```text
  wr_nbytes = min(seg_size_r - out_off, DST_BYTES)
  payload_nbytes = min(valid_total - out_off, wr_nbytes), or 0 after valid_total
  byteen = mask_dst_range(0, wr_nbytes)
  ```

  Payload lanes come from source chunks. Padding lanes inside `byteen` are written as zero. Lanes outside `byteen` are don't-care. This removes the need to clear `win_*`, accumulator data, or slot data for functional correctness.

- [x] Reset only metadata, not wide payload data.

  On reset or descriptor start, reset valid masks, valid byte counts, chunk counters, slot states, and occupancy. Do not add wide data clears except where existing reset style requires them for simulation hygiene. Functional protection must come from valid masks and `byteen`.

- [x] Preserve decoupled read/write segment advancement.

  Keep `rd_i_dim` and `wr_i_dim` independent. When read side crosses a segment, issue slot metadata must already identify how many valid bytes are in each slot. When write side crosses a segment, reset only the aligned converter's chunk counters and destination lane-valid mask. Do not perform a queue-wide tail drop.

- [ ] Parameterize `dma_mem_unit` bus widths.

  Deferred: the direct `dma_mem_unit_misal` unit harness was parameterized instead because the current `dma_mem_unit` wrapper test is stale relative to the active `VX_dma_node` interface. The focused aligned coverage now runs through `tb_VX_dma_mem_unit_misal` with `ENABLE_MISALIGN_P=0`.

  Change `hw/unittest/dma_mem_unit/tb_VX_dma_mem_unit.sv` from fixed localparams:

  ```systemverilog
  localparam int DCACHE_BYTES = 32;
  localparam int LMEM_BYTES   = 16;
  ```

  to module parameters plus localparams:

  ```systemverilog
  parameter int DCACHE_BYTES_P = 32;
  parameter int LMEM_BYTES_P   = 16;
  localparam int DCACHE_BYTES = DCACHE_BYTES_P;
  localparam int LMEM_BYTES   = LMEM_BYTES_P;
  ```

  The default continues to cover `DCACHE_BYTES > LMEM_BYTES`. Add a second run for `LMEM_BYTES > DCACHE_BYTES`.

- [ ] Add aligned tail and stale-lane tests.

  Partially covered in `tb_VX_dma_mem_unit_misal`: aligned-mode runs now exercise non-multiple segment sizes and padding in both width ratios. A dedicated consecutive-segment stale-lane test is still worth adding if this becomes a long-lived regression target.

  In `dma_mem_unit`, add cases where:

  - `seg_size` is not a multiple of `DCACHE_BYTES`.
  - `seg_size` is not a multiple of `LMEM_BYTES`.
  - `padding` is smaller than, equal to, and larger than each bus width.
  - two consecutive segments have different source data, so stale bytes from segment N would be detected in segment N+1.

## Verification Commands

Start from a configured build directory. If the build tree is stale or missing generated files:

```bash
cd build
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
```

Run unit tests directly instead of `test.sh` because the checked-in scripts call cleanup targets that remove build artifacts.

Aligned unit test, default width ratio:

```bash
make -C build/hw/unittest/dma_mem_unit sim SIM_EXEC=vcs
```

Aligned unit test, opposite width ratio after parameterizing the testbench:

```bash
make -C build/hw/unittest/dma_mem_unit sim SIM_EXEC=vcs PARAMS="-pvalue+tb_VX_dma_mem_unit.DCACHE_BYTES_P=16 -pvalue+tb_VX_dma_mem_unit.LMEM_BYTES_P=32"
```

Optional Verilator smoke checks:

```bash
make -C build/hw/unittest/dma_mem_unit sim SIM_EXEC=vlt CC=/usr/bin/gcc CXX=/usr/bin/g++ PARAMS="-GDCACHE_BYTES_P=32 -GLMEM_BYTES_P=16"
make -C build/hw/unittest/dma_mem_unit sim SIM_EXEC=vlt CC=/usr/bin/gcc CXX=/usr/bin/g++ PARAMS="-GDCACHE_BYTES_P=16 -GLMEM_BYTES_P=32"
```

Misaligned regression:

```bash
make -C build/hw/unittest/dma_mem_unit_misal sim SIM_EXEC=vcs
```

Node-level regression:

```bash
make -C build/hw/unittest/dma_node sim SIM_EXEC=vcs
```

Expected unit-test outcome:

- Simulation exits with status 0.
- `build/hw/unittest/dma_mem_unit/logs/sim.log` contains `ALL TESTS COMPLETED`.
- `build/hw/unittest/dma_mem_unit_misal/logs/sim.log` contains `ALL TESTS COMPLETED`.
- `build/hw/unittest/dma_node/logs/sim.log` contains its final pass message and no `$fatal`.

Executed focused verification:

- `make -C build/hw/unittest/dma_mem_unit_misal sim SIM_EXEC=vcs PARAMS="-pvalue+tb_VX_dma_mem_unit_misal.ENABLE_MISALIGN_P=0 -pvalue+tb_VX_dma_mem_unit_misal.DCACHE_BYTES_P=16 -pvalue+tb_VX_dma_mem_unit_misal.LMEM_BYTES_P=32"`: PASS, `9/9`.
- `make -C build/hw/unittest/dma_mem_unit_misal sim SIM_EXEC=vcs PARAMS="-pvalue+tb_VX_dma_mem_unit_misal.ENABLE_MISALIGN_P=0 -pvalue+tb_VX_dma_mem_unit_misal.DCACHE_BYTES_P=32 -pvalue+tb_VX_dma_mem_unit_misal.LMEM_BYTES_P=16"`: PASS, `9/9`.
- `make -C build/hw/unittest/dma_mem_unit_misal sim SIM_EXEC=vcs`: PASS, `2125/2125`.
- `make -C build/hw/unittest/dma_node sim SIM_EXEC=vcs`: blocked before simulation by existing VCS initializer-driver errors in `tb_VX_dma_node.sv`.

## FPGA QoR Verification

Use the same U55C hardware build shape that produced the failing report:

```bash
source configs/improve_no_tcu_lut_fexp.sh
make -C build/hw/syn/xilinx/xrt all TARGET=hw PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 PREFIX=improve_no_tcu_lut_fexp
```

Review these reports after the build:

- `build/hw/syn/xilinx/xrt/improve_no_tcu_lut_fexp_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/v++_vortex_afu.log`
- `build/hw/syn/xilinx/xrt/improve_no_tcu_lut_fexp_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/runme.log`
- `build/hw/syn/xilinx/xrt/improve_no_tcu_lut_fexp_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hier_utilization.rpt`
- `build/hw/syn/xilinx/xrt/improve_no_tcu_lut_fexp_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/slr_util_placed.rpt`
- `build/hw/syn/xilinx/xrt/improve_no_tcu_lut_fexp_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/full_util_placed.rpt`

Pass criteria:

- `u_dma_unit_misal` LUT count drops substantially from the current `77542 LUT` baseline.
- `runme.log` no longer reports `win_dcache[...]` or `win_lmem[...]` as dominant overlap nodes.
- The route completes, or at minimum `node overlaps` and `signals failed to route` drop by a large factor.
- SLR0 CLB utilization improves from the previous `98.35%` pressure point.

If route still fails, generate a real congestion report from the failed or routed DCP:

```tcl
open_checkpoint build/hw/syn/xilinx/xrt/improve_no_tcu_lut_fexp_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_routed_error.dcp
report_design_analysis -congestion -complexity -file dma_aligned_congestion.rpt
```

## Review Checklist

- [x] Aligned path has no wide variable shifts of `win_lmem` or `win_dcache`.
- [x] Aligned path has no dynamic write into a wide byte queue using `tmp_valid*8`.
- [x] Tail bytes are controlled by per-slot valid metadata, not by queue tail-drop shifts.
- [x] Destination byte enables are the source of truth for write lanes.
- [x] Padding lanes that are actually written are zero.
- [x] Both `L2G` and `G2L` pass when `DCACHE_BYTES > LMEM_BYTES`.
- [x] Both `L2G` and `G2L` pass when `LMEM_BYTES > DCACHE_BYTES`.
- [ ] `ENABLE_MISALIGN=1` regressions still pass.
- [ ] FPGA reports show `u_dma_unit_misal` no longer dominates congestion through `win_*` nets.
