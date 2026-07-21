# DMA Optimization

This note tracks RTL optimization points for the TMEM DMA engine involved in
the PnR overlap failure. Treat aligned-only mode and misaligned mode as
separate designs. Start with aligned-only mode because the GEMM TMEM path is
intended to move full 64-byte beats.

## Scope

Primary modules:

- `hw/rtl/mem/VX_dma_engine.sv`
- `hw/rtl/core/VX_dma_unit.sv`
- `hw/rtl/core/VX_dma_unit_align.sv`
- `hw/rtl/core/VX_dma_unit_misal.sv`
- `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv`
- `hw/rtl/mem/VX_tmem_subsystem.sv`

`VX_dma_unit.sv` is now the selector wrapper. `ENABLE_MISALIGN=0` instantiates
`VX_dma_unit_align.sv`; `ENABLE_MISALIGN=1` instantiates
`VX_dma_unit_misal.sv`. The current TMEM subsystem instantiates
`VX_dma_engine` with its default `ENABLE_MISALIGN=0`, so the GEMM TMEM DMA
path should synthesize through `VX_dma_unit_align.sv` unless a parent
explicitly overrides that parameter.

## Current Hotspots

The failing implementation reports about `90k` LUTs in `u_dma_engine`, with
about `11.2k` LUTs per `g_channel[*].u_dma_unit`. The small multiplier pipes
inside each channel are not the dominant LUT cost. The likely aligned-mode
pressure points are:

- dynamic 8-way slot selection from `slot_data_r[wr_expect_slot_r]`
- 512-bit write-data assembly from slot/window data
- slot state and valid-byte bookkeeping
- byte mask generation, even when the active GEMM path is full-beat aligned
- large combinational blocks that drive bus request data, next state, window
  updates, and slot retirement in the same cycle

The failed overlap names included `slot_data_r_reg_n_0_[0][233]` and
`wr_expect_slot_r_reg[0]`, so the first optimization should cut the slot-index
to slot-data path.

## Aligned-Only Mode Plan

The aligned-only path should be optimized before changing DMA channel count,
MXU tile size, thread count, or other performance-sensitive parameters.

### 1. Make Aligned Mode Structurally Explicit

Keep the implementation split instead of reintroducing `if (ENABLE_MISALIGN)`
branches inside one large module:

- Keep `VX_dma_unit_misal` for `ENABLE_MISALIGN=1`.
- Optimize `VX_dma_unit_align` for `ENABLE_MISALIGN=0`.
- Preserve the same config and done interfaces so `VX_dma_engine` does not
  need a protocol change.

Goal: let synthesis see a smaller design with no variable byte-drop logic, no
misaligned window shifts, and no partial-lane path.

### 2. Specialize For 64B To 64B Full-Beat Transfers

For the GEMM TMEM path, `VX_gemm_tmem_dma_ctrl` emits descriptors where:

- `SEG_SIZE = MEM_BLOCK_SIZE`
- `PAD = 0`
- source and destination bases are beat aligned
- each transfer beat is a full 64-byte word

In aligned-only mode, use this to simplify:

- `lane = 0`
- `wr_byteen = '1`
- `src_bytes = MEM_BLOCK_SIZE`
- `wr_nbytes = MEM_BLOCK_SIZE`
- `valid_total = SEG_SIZE`

This removes the need for range mask loops on the hot path. Keep simulation
assertions that fail if a supposedly aligned descriptor violates these
assumptions.

### 3. Register The Slot Read

Add a one-cycle stage between slot selection and write-data generation:

```text
slot_data_r[wr_expect_slot_r]
slot_valid_bytes_r[wr_expect_slot_r]
slot_state_r[wr_expect_slot_r]
        |
        v
wr_slot_data_r
wr_slot_valid_bytes_r
wr_slot_valid_r
        |
        v
write request assembly
```

This should cut the wide dynamic mux from the same cycle that creates
`wr_data`, updates the window, frees the slot, and advances
`wr_expect_slot_r`.

Use ready/valid semantics for this stage. Do not simply flop `valid` while
letting `ready` remain combinational; that can duplicate or drop beats under
backpressure.

### 4. Prefer A FIFO If Ordering Is Guaranteed

The slot array exists to tolerate out-of-order read responses. If the aligned
TMEM DMA channel can prove in-order responses for the relevant source bus,
replace the 8-entry indexed slot array with a FIFO-like queue:

- read response pushes `{data, valid_bytes}`
- write side pops in order
- output data is registered

This removes the `wr_expect_slot_r` indexed 512-bit read. Do this only after
confirming response ordering. If ordering is not guaranteed, keep the slot
array and use the registered slot-read stage above.

### 5. Split Request Assembly From State Update

The current DMA unit has large combinational regions that calculate request
valid/data, next state, occupancy changes, and byte/window movement together.
For aligned mode, split the hot path into smaller boundaries:

- source read request issue
- source response capture
- registered write slot
- destination write request issue
- descriptor index advance

Use existing `VX_elastic_buffer` or `VX_pipe_buffer` on ready/valid
boundaries. These helpers are already used elsewhere in the RTL and preserve
backpressure correctly.

### 6. Keep Outstanding Depth Initially

Do not reduce `RD_OUTSTANDING_CAP` as the first optimization. That can reduce
LUTs, but it also changes latency hiding and can affect performance. Keep the
depth at 8 while first removing avoidable muxing and adding registers. Only
evaluate a smaller depth after aligned-mode structure is cleaner and
performance data exists.

## Misaligned Mode Plan

Do not optimize misaligned mode in the same patch as aligned-only mode.
Misaligned mode has different bottlenecks:

- `WIN_BYTES = 2 * MAX_BYTES`
- variable byte drops
- variable shifts such as `tmp_win >> (src_bytes * 8)`
- partial byte masks
- lane-dependent write-data assembly

For misaligned mode, later options are:

- keep the current implementation only for paths that truly need byte
  misalignment
- reduce the window size if throughput loss is acceptable
- sequentialize byte shifts
- add pipeline stages around variable shifts and mask generation
- keep separate tests that intentionally use unaligned bases and strides

## Verification

Aligned-only changes need both RTL unit tests and implementation checks:

```bash
# From a configured build directory, after sourcing the intended config.
make -C hw/unittest/dma_engine
make -C hw/unittest/gemm_tmem_dma_ctrl
make -C hw/unittest/gemm_node_improve
```

For implementation:

1. Run synthesis/place to verify area moved in the expected direction.
2. Compare `hier_utilization.rpt` for `u_dma_engine` and each
   `g_channel[*].u_dma_unit`.
3. Run route or route replay and compare `report_route_status`.
4. Check that channel 4 no longer dominates the same congestion window.

Misaligned-mode changes need separate tests with unaligned source and
destination bases. Do not use aligned-only GEMM tests as proof that
misaligned mode still works.
