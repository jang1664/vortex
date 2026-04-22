# Extension — Out of Scope for the 2D Burst Refactor

This document tracks three planned extensions that are intentionally **out of scope** for the current `dma-burst-reorder` task, with concrete triggers and design sketches so a future refactor can pick up cleanly.

---

## 1. 3D descriptor (when AXI burst exceeds 4KB)

### Trigger

AXI4 INCR burst must not cross a 4KB address boundary. With `MEM_BLOCK_SIZE = 64 B`, the hard limit is:

```
MAX_BEATS_PER_BURST = 4096 / 64 = 64 beats
```

In the 2D formulation (BND0=beats/bank, BND1=banks/ch), this caps per-channel transfer size at
`BND0 × NUM_BURST_GROUPS = 64 × NUM_BURST_GROUPS` bus-words.

For the current fpint GEMM kernel, max per-channel transfers:

| Transfer | `ch_words` | beats/bank | Against 4KB limit |
|---|---|---|---|
| 32³ input | 32 | 8 | safe |
| 128³ input | 64 | 16 | safe |
| **256³ input** | **256** | **64** | **exactly at limit (boundary case)** |
| Future 512³ | 512 | 128 | **violates** — needs 3D |

### Proposed 3D layout

Introduce a sub-burst axis *inside* the bank so that each AXI INCR burst stays ≤ 64 beats. Natural nesting (inside-out):

```
i0 = beat       (0 .. MAX_BEATS_PER_BURST-1)   ← one AXI burst
i1 = sub_burst  (0 .. num_sub_bursts_per_bank-1)
i2 = bank       (0 .. NUM_BURST_GROUPS-1)
```

Strides (interleave mode):

| Stride | Value | Meaning |
|---|---|---|
| `SRC_ST0` (beat) | `NUM_HBM_BANKS × MEM_BLOCK_SIZE` | 2048 B — same-bank beat |
| `SRC_ST1` (sub_burst) | `SRC_ST0 × BND0` | per sub-burst jump, e.g. 131072 B for 64 beats |
| `SRC_ST2` (bank) | `HBM_BUS_STRIDE` | 512 B — next physical bank within channel |
| `DST_ST0` (beat) | `NUM_BURST_GROUPS × MEM_BLOCK_SIZE` | 256 B on TMEM |
| `DST_ST1` (sub_burst) | `DST_ST0 × BND0` | `256 × BND0` |
| `DST_ST2` (bank) | `MEM_BLOCK_SIZE` | 64 B |

Engine changes: no FSM change in spirit — it still latches `burst_len_r = BND0` at `cfg_fire` and emits one AR/AW per `BND0` consecutive reqs. Only the outer loop count grows (the engine sees more bursts total).

ctrl change: detect `ch_words / NUM_BURST_GROUPS > MAX_BEATS_PER_BURST` and split the inner count:
```
BND0 = MAX_BEATS_PER_BURST
BND1 = ceil((ch_words / NUM_BURST_GROUPS) / MAX_BEATS_PER_BURST)   // sub_bursts
BND2 = NUM_BURST_GROUPS
```
The final sub-burst may be partial — can be rounded up with `seg_size` padding or split into a tail descriptor.

### When to revisit
- Any new kernel shape where `M × K / NUM_CHANNELS / MEM_BLOCK_SIZE / NUM_BURST_GROUPS > 64` (currently: beyond 256³).
- Or when `MEM_BLOCK_SIZE` changes (future 32 B or 128 B bus).

---

## 2. Re-introduce `kernel.cmd.bound > 1` (multi-segment DMA)

### Background

The kernel ISA supports `bound` as an outer segment count — one DMA command can walk through multiple logical blocks in DRAM separated by `cmd.stride`. The current kernel (`tests/regression/fpint_gemm_ffn_hw_improve/kernel.cpp`) always emits `bound = 1`, so `VX_gemm_tmem_dma_ctrl` plumbed the value through `DMA_R_BND1` but nothing exercises it. The 2D refactor **removes this dead path** (BND1 is now banks; BND2 is reserved).

### When to re-introduce

If a future kernel needs multi-segment DMA (e.g., strided batches of the same shape with a programmable DRAM step), one of:

**Option A — use `BND2` as the outer bound**
- Works only while the inner two dimensions stay at `BND0=beats, BND1=banks` (i.e., no simultaneous 3D sub-burst split from §1).
- strides:
  - `SRC_ST2 = cmd.stride_src` (kernel-provided)
  - `DST_ST2 = cmd.stride_dst`
- `VX_dma_unit_misal` already supports 3 dimensions natively.

**Option B — upper ctrl FSM emits a descriptor per segment**
- Required when both §1 (3D for 4KB split) and bound>1 must coexist (need a 4th dimension).
- `VX_gemm_tmem_dma_ctrl` gets a new outer state that iterates `cmd.bound` and re-programs `cfg_reg_if` for each segment.
- `VX_dma_unit_misal` unchanged.

### Checklist for re-introduction
1. Re-thread `cmd.bound` from `gemm_unified_cmd_t` → `VX_gemm_tmem_dma_ctrl` (currently dropped).
2. Pick A or B based on whether §1 is simultaneously active.
3. Update SVA in `VX_dma_engine` to accept the new `BND2 != 1` shape.
4. Add unit-test case in `hw/unittest/gemm_tmem_dma_ctrl/` with `bound > 1`.

---

## 3. `PLATFORM_MEMORY_INTERLEAVE = 0` (contiguous mode)

### Current status

`VX_mem_remap.sv` is a 30-line module implementing the interleave→contiguous transform only. No bypass path exists for the non-interleaved case. `VX_dma_engine.sv` (post-refactor) drives requests through `VX_mem_remap` unconditionally. A 2D descriptor with `SRC_ST0 = NUM_HBM_BANKS × MEM_BLOCK_SIZE = 2048 B` only makes sense when the SW-side address space is interleaved.

The 2D refactor adds an `initial $fatal` guard in `VX_dma_engine` (and ctrl computes the correct strides conditional on `PLATFORM_MEMORY_INTERLEAVE`) but does not exercise the contiguous path.

### Support plan

To enable `PLATFORM_MEMORY_INTERLEAVE = 0`:

1. **VX_mem_remap.sv** — add identity bypass:
   ```systemverilog
   if (!`PLATFORM_MEMORY_INTERLEAVE)
     assign hbm_address = m_address;
   else
     // existing interleave remap
   ```

2. **VX_gemm_tmem_dma_ctrl.sv** — ctrl already has `PLATFORM_MEMORY_INTERLEAVE`-conditional stride computation in the 2D refactor; no change expected.

3. **Bank assignment logic** — in contiguous mode, each channel gets one contiguous bank range, not a 1/N interleaved slice. The "NUM_BURST_GROUPS = banks-per-channel" decomposition still holds only if the channel's data spans multiple banks. For contiguous mode, typically `NUM_BURST_GROUPS = 1` (each channel owns one bank region). Confirm `ch_src_base`, `ch_dst_base` still map correctly.

4. **Remove `$fatal` guard** once validated.

### Tests needed
- Unit test `hw/unittest/dma_engine/` parametrized for `PLATFORM_MEMORY_INTERLEAVE=0`.
- Regression on `fpint_gemm_ffn_hw_improve` with the corresponding build flag.

---

## References
- `agent-tasks/dma-burst-reorder/plan.md` — §Design, §Scope & Assumptions
- `hw/rtl/VX_config.vh` — `PLATFORM_MEMORY_INTERLEAVE`, `PLATFORM_MEMORY_NUM_BANKS`, `NUM_DMA_CHANNELS`, `MEM_BLOCK_SIZE`, `HBM_BUS_STRIDE`
- `hw/rtl/core/VX_mem_remap.sv` — current interleave-only transform
- `hw/rtl/core/VX_dma_unit_misal.sv` — 3D strided FSM (already supports needed extensions)
- `docs/hbm-bank-interleaving.md` — end-to-end address remap flow
