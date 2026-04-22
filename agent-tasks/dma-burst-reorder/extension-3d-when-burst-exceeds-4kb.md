# Extension — Future Work

This document tracks extensions that are **out of scope** for the current `dma-burst-reorder` task. Triggers and design sketches so future refactors can pick up cleanly.

> Note: the original "3D descriptor when AXI burst exceeds 4KB" item has been **moved in-scope** and implemented as the primary design (see `plan.md §Design`). The 4KB boundary issue is in fact triggered not only by large bursts but also by misaligned `bank_offset_within_4KB`, so the 3D (beat × sub-burst × bank) form is now the default.

---

## 1. Non-divisible `ch_words ≥ NUM_BURST_GROUPS` (Option B)

### Problem
`VX_dma_unit_misal` uses a uniform 3D loop (`BND0 × BND1 × BND2`) where every iteration has the same inner count. For `ch_words = k·NUM_BURST_GROUPS + r, 0 < r < NUM_BURST_GROUPS` (e.g., `ch_words = 6, NBG = 4` → banks 0,1 want 2 beats each, banks 2,3 want 1 beat each), a single descriptor cannot express the non-uniform burst lengths.

### Current Behavior (Option A, in scope)
Fall back to single-beat linear walk: `BND0=1, BND1=ch_words, BND2=1`. Correct but forfeits burst efficiency — e.g. `ch_words=6` → 6 × AR `len=0` instead of the optimal `2×len=1 + 2×len=0 = 4 AR`.

### Kernel situation
Current fpint GEMM kernel never emits `ch_words ≥ NUM_BURST_GROUPS` with non-divisible `ch_words`. Smallest is `ch_words=2 < NBG` (always fallback). So Option A is sufficient today.

### When to re-introduce (Option B)
If a future kernel emits `ch_words = k·NBG + r` with `r > 0` and `ch_words ≥ NBG`, AND the performance cost of single-beat fallback is material.

### Design sketch: dual-descriptor per command
`VX_gemm_tmem_dma_ctrl` emits **two descriptors back-to-back** per DMA command when non-divisible:

- **Desc 1 (full banks)**: `r` banks each getting `⌈ch_words/NBG⌉` beats
  - BND2 = `r`, SRC_ST2/DST_ST2 as usual (bank stride)
  - BND0, BND1 computed by S algorithm on `⌈ch_words/NBG⌉`
- **Desc 2 (partial banks)**: `NBG - r` banks each getting `⌊ch_words/NBG⌋` beats
  - Base addr offset by `r × HBM_BUS_STRIDE` (logical) to skip full-bank region
  - BND2 = `NBG - r`, same S computation on `⌊ch_words/NBG⌋`

### Ctrl FSM changes
```
current:  S_IDLE → S_PROG → S_WAIT_DONE → S_DONE
proposed: S_IDLE → S_PROG1 → S_WAIT_DONE1 → S_PROG2 → S_WAIT_DONE2 → S_DONE
```
For divisible cases, skip S_PROG2 (equivalent to current single-desc path).

### Engine changes
**None** — engine just sees two back-to-back `cfg_fire` events and processes each independently.

---

## 2. `kernel.cmd.bound > 1` (multi-segment DMA)

### Background
The kernel ISA supports `bound` as an outer segment count — one DMA command walks through multiple logical blocks separated by `cmd.stride`. The current kernel always emits `bound = 1`, so `VX_gemm_tmem_dma_ctrl` formerly plumbed it through `DMA_R_BND1` but nothing exercised it. The 3D refactor **removes this dead path** (BND1 is now sub-bursts within a bank; BND2 is banks).

### When to re-introduce
If a future kernel needs multi-segment DMA (e.g., strided batches of same shape with programmable DRAM step), one of:

**Option A — use kernel-level loop**
Upper ctrl FSM emits a descriptor per segment (similar to §1's dual-descriptor approach). No RTL changes beyond ctrl FSM.

**Option B — use `BND3` (new dimension)**
Would require extending `VX_dma_unit_misal` from 3D to 4D. Large scope.

### Checklist for re-introduction
1. Re-thread `cmd.bound` from `gemm_unified_cmd_t` → `VX_gemm_tmem_dma_ctrl` (currently dropped, `cmd.bound == 1` SVA)
2. Pick Option A (preferred for simplicity)
3. Update SVA in `VX_dma_engine` to accept multiple `cfg_fire` per "logical" command
4. Add unit-test case with `bound > 1`

---

## 3. `PLATFORM_MEMORY_INTERLEAVE = 0` (contiguous mode)

### Current status
`VX_mem_remap.sv` is a 30-line module implementing the interleave→contiguous transform only. No bypass path exists for the non-interleaved case. `VX_dma_engine.sv` drives requests through `VX_mem_remap` unconditionally. A 3D descriptor with `SRC_ST0 = NUM_HBM_BANKS × MEM_BLOCK_SIZE = 2048 B` only makes sense when the SW-side address space is interleaved.

The refactor adds an `initial $fatal` guard in `VX_dma_engine` and `VX_gemm_tmem_dma_ctrl` (and ctrl computes the correct strides conditional on `PLATFORM_MEMORY_INTERLEAVE`) but does not exercise the contiguous path.

### Support plan
To enable `PLATFORM_MEMORY_INTERLEAVE = 0`:

1. **VX_mem_remap.sv** — add identity bypass:
   ```systemverilog
   if (!`PLATFORM_MEMORY_INTERLEAVE)
     assign hbm_address = m_address;
   else
     // existing interleave remap
   ```

2. **VX_gemm_tmem_dma_ctrl.sv** — ctrl already has `PLATFORM_MEMORY_INTERLEAVE`-conditional stride computation in the 3D refactor; no change expected.

3. **Bank assignment logic** — in contiguous mode, each channel gets one contiguous bank range, not a 1/N interleaved slice. The "NUM_BURST_GROUPS = banks-per-channel" decomposition still holds only if the channel's data spans multiple banks. For contiguous mode, typically `NUM_BURST_GROUPS = 1` (each channel owns one bank region). Confirm `ch_src_base`, `ch_dst_base` still map correctly.

4. **Remove `$fatal` guard** once validated.

### Tests needed
- Unit test `hw/unittest/dma_engine/` parametrized for `PLATFORM_MEMORY_INTERLEAVE=0`.
- Regression on `fpint_gemm_ffn_hw_improve` with the corresponding build flag.

---

## References
- `agent-tasks/dma-burst-reorder/plan.md` — §Design (3D scheme), §Scope
- `hw/rtl/VX_config.vh` — `PLATFORM_MEMORY_INTERLEAVE`, `PLATFORM_MEMORY_NUM_BANKS`, `NUM_DMA_CHANNELS`, `MEM_BLOCK_SIZE`, `HBM_BUS_STRIDE`
- `hw/rtl/core/VX_mem_remap.sv` — current interleave-only transform
- `hw/rtl/core/VX_dma_unit_misal.sv` — 3D strided FSM (already supports needed extensions)
- `docs/hbm-bank-interleaving.md` — end-to-end address remap flow
