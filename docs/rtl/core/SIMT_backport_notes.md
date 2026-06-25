# SIMT Backport Notes

This note captures the current SIMT-related fixes that are present in this
branch so they can be reapplied on another branch without replaying the whole
debug session.

The current tree contains three separate pieces of work:

1. A confirmed barrier / LSU-drain fix adapted from upstream commit
   `f9c79bb40` (`rtl/sim: BAR opcode drains LSU before suspending warps`).
2. A partial fairness backport related to upstream commit `5d0f1e60f`
   (`hw: fair issue/operand arbitration to fix NW16 starvation deadlocks`).
3. An extra cache write-through replay suppression change matching upstream
   `b9ac4aaa1` (`fixed cache bank WT replay duplicate`).

A separate 32-thread GEMM lane-split issue is still open and should be treated
separately from the SIMT fixes documented here.

## 1. Confirmed Backport: Barrier Must Drain LSU

### Problem

`vx_barrier` / `vx_barrier_arrive` could suspend a warp while LSU-side local
memory writes were still in flight. A later warp resumed after the barrier and
read LMEM before the earlier stores had committed.

That violates the expected local-memory fence behavior of a barrier and can
show up as SIMT data-ordering failures.

### Upstream Intent

Upstream commit `f9c79bb40` exports `lsu_sched_drained` through
`warp_ctl_if` and makes BAR wait until the LSU scheduler is empty.

This branch does not match upstream file layout exactly, so the same idea was
adapted locally by threading a direct `lsu_drained` signal through the execute
path.

### Local RTL Changes

#### `hw/rtl/core/VX_lsu_slice.sv`

- Export `lsu_drained`
- Drive it from:
  - request queue empty
  - no active execute input
  - no `fence_lock`

Current local condition:

```systemverilog
assign lsu_drained = req_queue_empty && ~execute_if.valid && ~fence_lock;
```

#### `hw/rtl/core/VX_lsu_unit.sv`

- Collect per-slice `lsu_drained`
- AND-reduce to one core-level signal

```systemverilog
assign lsu_drained = &per_block_lsu_drained;
```

#### `hw/rtl/core/VX_execute.sv`

- Add local `lsu_drained` wire
- Connect `VX_lsu_unit` output to that wire
- Pass the wire into `VX_sfu_unit`

#### `hw/rtl/core/VX_sfu_unit.sv`

- Add `input wire lsu_drained`
- Forward it into `VX_wctl_unit`

#### `hw/rtl/core/VX_wctl_unit.sv`

- Add `input wire lsu_drained`
- Detect BAR drain condition:

```systemverilog
wire bar_drain = execute_if.valid && is_bar && execute_if.data.eop && ~lsu_drained;
```

- Hold BAR in place until drained by gating both `valid_in` and
  `execute_if.ready`

```systemverilog
.valid_in  (execute_if.valid && ~bar_drain)
assign execute_if.ready = rsp_buf_ready && ~bar_drain;
```

### Local SimX Changes

This branch keeps LSU and SFU logic in `sim/simx/func_unit.*`, so the SimX
adaptation differs from upstream file names but implements the same behavior.

#### `sim/simx/core.h`
#### `sim/simx/core.cpp`

- Add `Core::lsu_drained() const`

#### `sim/simx/func_unit.h`
#### `sim/simx/func_unit.cpp`

- Add `LsuUnit::drained() const`
- Consider the LSU drained only when:
  - no pending loads
  - no pending addresses
  - no LSU input traffic
  - no block-level pending read requests
  - no fence lock
  - no traffic left in LMEM switch / coalescer / dcache / local memory ports

- Stall BAR in `SfuUnit::tick()` until `core_->lsu_drained()` is true

```cpp
if (wctl_type == WctlType::BAR && trace->eop && !core_->lsu_drained())
    continue;
```

### Regression Added

#### `tests/kernel/conform/main.cpp`
#### `tests/kernel/conform/tests.cpp`
#### `tests/kernel/conform/tests.h`

- Add `test_barrier_lmem_ordering()`

This regression writes multiple LMEM locations before a barrier and then checks
that the neighboring warp sees the post-barrier final values, not stale data.

### Backport Recommendation

If the target branch is close to upstream `f9c79bb40`, prefer the upstream
shape:

- `VX_core.sv`
- `VX_warp_ctl_if.sv`
- `VX_wctl_unit.sv`
- `sim/simx/lsu_unit.*`
- `sim/simx/sfu_unit.cpp`

If the target branch looks like this branch instead, replicate the local
signal-threading through:

- `VX_lsu_slice.sv`
- `VX_lsu_unit.sv`
- `VX_execute.sv`
- `VX_sfu_unit.sv`
- `VX_wctl_unit.sv`
- `sim/simx/core.*`
- `sim/simx/func_unit.*`

## 2. Partial Fairness Backport

### Upstream Intent

Upstream commit `5d0f1e60f` fixes starvation deadlocks at high warp count
(`NW16`) with three changes:

1. Replace `VX_gto_arbiter.sv` oldest-select implementation
2. Change `VX_operands.sv` merge arbiter from fixed-priority to round-robin
3. Change `VX_scoreboard.sv` output buffer to a skid buffer

### What Exists in This Branch

This branch does not have the same scheduler structure as upstream:

- `hw/rtl/libs/VX_gto_arbiter.sv` is not present
- the exact `VX_scoreboard.sv` change was not applied

Only one upstream hunk was applied directly:

#### `hw/rtl/core/VX_operands.sv`

Change:

```systemverilog
.ARBITER("P") -> .ARBITER("R")
```

Reason:

- the operand collectors are partitioned by `wis % NUM_OPCS`
- a fixed-priority merge can starve the highest-index collector
- round-robin removes that collector starvation pattern

### Branch-Local Adaptation Present in This Tree

#### `hw/rtl/core/VX_dispatch_unit.sv`

Current local tree also changes:

```systemverilog
.TYPE("P") -> .TYPE("M")
```

Important caveat:

- this is not part of upstream `5d0f1e60f`
- it is a local adaptation that was present in the current worktree
- it was not independently proven to be the root-cause fix

### Backport Recommendation

For another branch:

- apply `VX_operands.sv` round-robin change
- if that branch carries upstream-style `VX_gto_arbiter.sv`, prefer the
  original upstream `5d0f1e60f` hunk instead of copying the local
  `VX_dispatch_unit.sv` adaptation blindly
- only carry the `VX_dispatch_unit.sv` `.TYPE("M")` change if the target
  branch has the same local scheduler topology and you plan to validate it
  explicitly

## 3. Extra Cache Fix In Current Tree

### File

#### `hw/rtl/cache/VX_cache_bank.sv`

Current local tree includes:

```systemverilog
assign mreq_queue_push = ((do_read_st2 && ~is_hit_st2 && ~mshr_pending_st2)
                      || (do_write_st2 && ~is_replay_st2))
                      && ~pipe_stall;
```

instead of:

```systemverilog
assign mreq_queue_push = ((do_read_st2 && ~is_hit_st2 && ~mshr_pending_st2)
                      || do_write_st2)
                      && ~pipe_stall;
```

### Meaning

This suppresses duplicate write-through memory requests during replay.

### Provenance

This matches upstream commit `b9ac4aaa1` (`fixed cache bank WT replay
duplicate`).

### Scope

This fix is orthogonal to the barrier-drain SIMT fix above.

It should be treated as an additional safe backport, not as the main SIMT
ordering fix.

## Known Limitations

### `NUM_THREADS=32` is still broken

The current tree is not clean at 32 threads.

Current symptoms:

- VCS compile warnings from `hw/rtl/mem/VX_mem_bus_split.sv`
  (`Select index out of bounds`)
- runtime `X` propagation entering the GEMM LMEM / prealigner / MXU path
- the test did not reach a trustworthy pass state

Likely root cause in the current tree:

- `NUM_LSU_LANES` defaults to `SIMD_WIDTH`, so `NUM_THREADS=32` also makes
  `NUM_LSU_LANES=32`
- `VX_gemm_node.sv` still hard-codes the input / scale-zero / output GEMM DMA
  buses to `GEMM_*_DATA_SIZE = 64B`
- the same file then instantiates `VX_mem_bus_split` with
  `.NUM_LANES(`NUM_LSU_LANES)` and `LANE_DATA_SIZE=LSU_WORD_SIZE`
- that split block assumes the wide bus payload width is
  `NUM_LANES * LANE_DATA_SIZE`

So at 32 threads the code is effectively trying to split a fixed 64-byte GEMM
bus into 32 lanes of 8 bytes each, which is structurally inconsistent. The
comment in `VX_gemm_node.sv` that says
`GEMM_*_DATA_SIZE = NUM_LSU_LANES * LSU_WORD_SIZE = 64B` is only true for the
`NUM_LSU_LANES=8` setup.

So this note should not be read as "the tree is fully fixed for all SIMT
widths". It documents the current backport state only.

## Minimal Backport Checklist

If the goal is to reproduce the current SIMT fix set on another branch, the
minimum set to port is:

1. `hw/rtl/core/VX_operands.sv`
2. `hw/rtl/core/VX_lsu_slice.sv`
3. `hw/rtl/core/VX_lsu_unit.sv`
4. `hw/rtl/core/VX_execute.sv`
5. `hw/rtl/core/VX_sfu_unit.sv`
6. `hw/rtl/core/VX_wctl_unit.sv`
7. `sim/simx/core.h`
8. `sim/simx/core.cpp`
9. `sim/simx/func_unit.h`
10. `sim/simx/func_unit.cpp`
11. `tests/kernel/conform/main.cpp`
12. `tests/kernel/conform/tests.cpp`
13. `tests/kernel/conform/tests.h`

Optional / separate:

1. `hw/rtl/cache/VX_cache_bank.sv`
2. `hw/rtl/core/VX_dispatch_unit.sv`

## Suggested Validation On The Target Branch

1. Run the conform regression and confirm `test_barrier_lmem_ordering()`
   passes.
