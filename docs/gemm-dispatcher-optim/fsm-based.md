# GEMM Dispatcher Optimization — FSM-Based CMD Generation

Replace the current SW-driven instruction-stream dispatcher with the
FSM-based one already in use on the `fpint` branch, then promote the DMA
tile dimensions (`DMA_MT`, `DMA_KT`, `DMA_NT`) from RTL `define`s to MMIO
configuration registers.

- Background (single-warp dispatcher cost): `docs/gpu-single-thread-control-stall.md`
- Companion plans (orthogonal optimisations): `docs/gemm-dispatcher-optim/DAE.md`
- Empirical FSDB stall analysis: `tools/mmio_analysis/RESULTS.md`

## 0. Problem recap

`fpint_improve` today serializes one GEMM job through this SW loop:

```
for each raw 64-bit instruction word:
  *((volatile u64*)(GEMM_REG_BASE_ADDR + 8)) = word;   // MMIO store
```

`VX_gemm_job_frontend` accepts every store as one beat into
`VX_instruction_if`; `VX_cmd_constructor` re-aggregates 1-3 beats per
high-level command and forwards a `gemm_unified_cmd_t` to the parent
queue. Each tile produces O(20) raw words, and a 128×128×128 problem on
a 1K×1K×1K matrix needs ~512 tiles → ~10 K MMIO stores.

FSDB measurement on `vcs_cosim.fsdb` showed:

- 100 % of MMIO writes are accepted with `req_ready=1` (no backpressure).
- The bottleneck is the **scheduler issue cadence** at 1 active warp:
  schedule→fetch→decode→unlock chain is 7 cycles, so ~85 % of cycles the
  core has `ready_warps == 0` — the scalar pipeline starves the
  dispatcher even though the MMIO path is idle.
- Static disasm shows 0–11 scalar instructions between consecutive
  `stream_send`s (address gen, `arg` field loads, branches).

The FSM-based design moves the entire tile loop into hardware: SW writes
~43 32-bit job-descriptor registers **once**, sets a CONTROL bit, then
polls for completion. The number of MMIO transactions drops from
O(K_tiles · M_tiles · N_tiles · per_tile_words) to **O(43)** — a >100×
reduction in dispatcher MMIO traffic for typical problems, and the
single-warp issue cadence becomes irrelevant.

## 1. fpint branch FSM analysis

### 1.1 Module map (`fpint`)

```
                  MMIO writes (40 × u32 + 1 CONTROL)
                                │
                                ▼
                ┌─────────────────────────────────┐
                │ VX_job_frontend                 │
                │  ├─ VX_job_desc_mmio_regs       │  per-entry reg file
                │  └─ VX_job_dispatcher           │  pulls valid entries → cfg_reg_if
                └─────────────┬───────────────────┘
                              │ VX_config_reg_if (40 × 32b + entry_id + valid/ready)
                              ▼
                ┌─────────────────────────────────┐
                │ VX_gemm_ctrl                    │
                │  ├─ VX_gemm_fsm   (cmd source)  │  reads cfg → emits unified cmd stream
                │  ├─ parent FIFO   (depth 4)     │
                │  ├─ VX_gemm_sync                │  WAIT/NOTIFY + child demux
                │  └─ child FIFO[5] (depth 4)     │  i / w / sz / out / dma
                └─────────────────────────────────┘
```

Key files copied from `fpint`:

| Path                                          | Lines  | Role                                   |
|-----------------------------------------------|-------:|----------------------------------------|
| `hw/rtl/core/VX_config_reg_if.sv`             | 27     | Config-reg interface (NUM, DW=32)      |
| `hw/rtl/core/VX_job_desc_mmio_regs.sv`        | ~600   | Per-entry reg file + ALLOC + state     |
| `hw/rtl/core/VX_job_dispatcher.sv`            | ~250   | Picks valid entries → cfg_reg_if       |
| `hw/rtl/core/VX_job_frontend.sv`              | 105    | Wrapper: regs + dispatcher             |
| `hw/rtl/core/gemm/VX_gemm_fsm.sv`             | 2024   | Tile-loop FSM, emits cmd stream        |
| `hw/rtl/core/gemm/VX_gemm_fsm_if.sv`          | 67     | FSM ↔ ctrl interface                   |
| `hw/rtl/core/gemm/VX_gemm_ctrl.sv` (cfg ver.) | 375    | cfg_reg → FSM → sync → children        |

`fpint_improve` already contains all of these (they were merged from
`fpint`) but **none of them are on the active datapath** — the active
gemm_node uses `VX_gemm_job_frontend` (cmd-stream MMIO) +
`VX_cmd_constructor`-based `VX_gemm_ctrl`. They are de facto dead code
that this plan revives.

### 1.2 SW interface (`fpint` kernel)

From `tests/regression/fpint_gemm_ffn_hw/kernel.cpp`:

```c
// 1. Allocate one entry (atomic doorbell read)
r = mmio_read32(GEMM_REG_BASE_ADDR);
eid        = (r >> JOB_MMIO_ALLOC_ENTRY_LSB) & ENTRY_MASK;
generation = (r >> JOB_MMIO_ALLOC_GEN_LSB)   & GEN_MASK;

// 2. Program 43 regs at base + 8 + eid * stride  (32-bit beats)
job_write_reg64(eid, REG_INPUT_BASE_LO,  arg->input_base);
job_write_reg64(eid, REG_WEIGHT_BASE_LO, arg->weight_base);
...
job_write_reg32(eid, REG_M_ORIG, arg->M);
job_write_reg32(eid, REG_N_ORIG, arg->N);
job_write_reg32(eid, REG_K_ORIG, arg->K);
job_write_reg32(eid, REG_M_TARGET, part.target_M);
...
job_write_reg32(eid, REG_WTRANS, arg->WTRANS);
job_write_reg32(eid, REG_QDIR,   arg->QDIR);

// 3. Kick off
job_write_reg32(eid, REG_CONTROL, 1u);

// 4. Poll for completion (generation bumps OR valid bit clears)
while (...) { ctrl = job_read_reg32(eid, REG_CONTROL); ... }
```

Per-entry layout (currently `GEMM_CFG_REG_NUM = 40`, fpint and
`fpint_improve` agree):

```
  0  CONTROL                   29 M_ORIG
  1  INPUT_BASE_LO             30 N_ORIG
  2  INPUT_BASE_HI             31 K_ORIG
  3  WEIGHT_BASE_LO            32 QBLK_ORIG (== log2(QBLK))
  4  WEIGHT_BASE_HI            33 M_TARGET
  5  OUTPUT_BASE_LO            34 N_TARGET
  6  OUTPUT_BASE_HI            35 K_TARGET
  7  SCALE_BASE_LO             36 M_START
  8  SCALE_BASE_HI             37 N_START
  9  ZP_BASE_LO                38 WTRANS
 10  ZP_BASE_HI                39 QDIR
 11..28  LMEM_*BUF{0,1}_LO/HI  (i/w/sc/zp/o, double-buffered)
```

### 1.3 FSM internals

`VX_gemm_fsm.sv` (2024 lines) latches the cfg snapshot at the rising
edge of `cfg_reg_if.regs[CFG_R_CONTROL][0]` (start), then runs three
nested loops in HW:

- **outer**: NT-tile (n_start..n_start+target_N step DMA_NT)
- **middle**: MT-tile (m_start..m_start+target_M step DMA_MT)
- **inner**: KT-tile (0..K_target step DMA_KT) accumulating into a
  scratch acc-mem; only the last KT iteration emits ACC2LMEM + LMEM2DRAM
  store.

For each `(mt, nt, kt)` it emits a fixed sequence of unified commands:

```
IBUF_LDMA(buf)  + WBUF_LDMA(buf) + SCBUF_LDMA(buf) + ZPBUF_LDMA(buf)
  → NOTIFY tile_done
  loop over MXU sub-tiles (MXU_KT × MXU_NT):
    WAIT tile_done
    W_LDMA_MXU + SC_LDMA_MXU + ZP_LDMA_MXU + I_LDMA_ARM
  if last kt: ACC2LMEM + DMA_ST(out) + NOTIFY job_done
```

Sync register IDs `RID_T0..RID_G1`, `RID_O` are statically allocated;
NOTIFY/WAIT pairs ping-pong on `buf_sel` to overlap LDMA and compute.

### 1.4 QDIR is not hardware-fixed

The header comment in `VX_gemm_fsm.sv:62` says
`Quantization direction(QDIR_COL) = column-wise 로 "고정"`. **The
comment is stale.** The actual register-load logic at line 963 latches
QDIR from cfg:

```systemverilog
job_d.qdir = cfg_reg_if.regs[CFG_R_QDIR][0];
```

and ~12 conditionals throughout the FSM (lines 485, 504, 874, 897,
1026, 1062, 1166, 1202, 1716, plus stride/byte-count selectors at 1307,
1329, 1417, 1444) branch on `job_q.qdir`. The cmd `flags` field also
forwards `job_q.qdir` to downstream LDMAs (line 1277, 1310, 1332, 1381,
1420, 1447, 1480) so the QCOL/QROW behaviour propagates correctly.
WTRANS is similarly cfg-driven (line 1277, 1381 etc.) Both are
runtime-variable today.

The plan therefore inherits fpint's full op coverage (QDIR_COL +
QDIR_ROW, WTRANS=0/1) without any FSM extension.

## 2. Current branch (`fpint_improve`) state

### 2.1 Active datapath

```
SW → vortex core → DCache MMIO →
  VX_gemm_job_frontend (cmd-stream)
   └─ issue_if : VX_instruction_if  (one 64-bit word per beat)
       │
       ▼
  VX_gemm_ctrl
   ├─ VX_cmd_constructor   (raw words → unified cmd)   ← KILL THIS
   ├─ parent FIFO
   ├─ VX_gemm_sync
   └─ child FIFO[5]
```

The active `VX_gemm_ctrl.sv` (current branch) takes
`instruction_if : VX_instruction_if.slave` and instantiates
`VX_cmd_constructor` (`hw/rtl/core/gemm/VX_gemm_ctrl.sv:83`).

### 2.2 Dormant FSM-based copies

Already merged from `fpint`, currently unused on the main datapath:

- `hw/rtl/core/VX_config_reg_if.sv`
- `hw/rtl/core/VX_job_frontend.sv`
- `hw/rtl/core/VX_job_desc_mmio_regs.sv`
- `hw/rtl/core/VX_job_dispatcher.sv`
- `hw/rtl/core/gemm/VX_gemm_fsm.sv`
- `hw/rtl/core/gemm/VX_gemm_fsm_if.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl_with_ldma.sv` (older monolithic variant)

`hw/rtl/VX_config.vh:1128` already defines
`GEMM_CFG_REG_NUM = 40`, and lines 1142–1165 define all `JOB_MMIO_*`
bit positions. `GEMM_REG_BASE_ADDR = 0x1080` (XRT
`0x0000_FFFF_0000_0000`) is shared by both designs — only the access
pattern differs.

### 2.3 TMEM (not LMEM) and tile-contiguous DRAM layout

Unlike `fpint`, `fpint_improve` uses **TMEM** as the on-chip scratch.
The host-side `compute_tmem_layout()` (in `main.cpp` of either
regression test) already computes per-job TMEM layout from DMA_MT/KT/NT
and the QDIR-dependent scale/zp footprint, then passes the ten
`lmem_*buf{0,1}_base` addresses through `kernel_arg_t`. (The kargs
field name is still `lmem_*` — historical, refers to the same TMEM
buffers today.) This is exactly the host-side allocation contract the
FSM needs: SW lays out TMEM around runtime MT/KT/NT, programs the bases
via cfg_reg, and the FSM consumes them as opaque pointers.

**Tile-contiguous DRAM layout (locked architectural premise).** The
host-side test (`fpint_gemm_ffn_hw/main.cpp`) lays out **each tile as a
contiguous byte run in DRAM** — the bytes of a tile occupy
`[tile_base, tile_base + tile_total_bytes)` with no internal stride
holes. Concretely:

- input tile : `MT × KT × FP16_BYTES`        contiguous
- weight tile: `KT × NT / 2`                 contiguous (int4 packed)
- scale tile : `groups_full × NT × FP16_BYTES` contiguous
- zp tile    : `groups_full × NT × INT16_BYTES` contiguous
- output tile: `MT × NT × FP16_BYTES`        contiguous

Successive tiles in DRAM are placed back-to-back at full-tile stride
(the comment block §4 of `VX_gemm_fsm.sv` already documents this).
Edge tiles are partial; the **DRAM stride between tile bases stays
full-tile-sized**, only the DMA's per-tile byte count shrinks via
`mt_eff/kt_eff/nt_eff`.

**Address-alignment constraints (HW contract — must hold for every
`base_addr(tile)`, not just the whole matrix).** The HBM↔TMEM DMA
engine assumes the source and destination bases land on the same
HBM-channel slot so that per-channel descriptors can be issued without
cross-channel reorder. Concretely, every kernel-issued DMA cmd must
satisfy:

```
HBM_addr  % 64  == 0            // 64-byte (cache-line) alignment
TMEM_addr % 64  == 0            // 64-byte alignment
HBM_addr  % 512 == TMEM_addr % 512   // same channel-slot
                                      // (= NUM_DMA_CHANNELS * MEM_BLOCK_SIZE = 8 × 64)
```

The third constraint is enforced by
`VX_gemm_tmem_dma_ctrl.sv:487-493`:

```systemverilog
assert (gemm_dma_ctrl_if.cmd.rs1_data[BUS_WORD_SHIFT +: NUM_CH_SHIFT]
     == gemm_dma_ctrl_if.cmd.rs2_data[BUS_WORD_SHIFT +: NUM_CH_SHIFT])
```

Violating this routes a channel's transaction to the wrong HBM port;
with the new HBM[4i:4i+3] sp mapping (platforms.mk) it produces
out-of-window AXI addresses.

The 64-byte constraint is enforced inside `VX_lmem_dma_misal.sv:165`
(`ENABLE_MISALIGN = 0` is forced for every instance — see Decision #7).

**Critical: these constraints apply per-tile, not just per-matrix.**
Every tile's base address used in a DMA cmd —
`input_tile_addr(j, mt, kt)`, `weight_tile_addr(...)`, `scale_tile_addr(...)`,
`zp_tile_addr(...)`, `out_tile_addr(...)`, plus the corresponding
TMEM-side `lmem_*buf{0,1}_base` — must independently satisfy all three
constraints. **This is the reason tile-contiguous layout is forced
above:** if successive tiles were placed at any non-`512-byte`-multiple
stride in DRAM, some tiles would land on the wrong HBM channel-slot
relative to their TMEM destination and trip the assertion. Tile-
contiguous layout with the per-tile sizes listed (each pow2 × pow2 ×
BPE for pow2 MT/KT/NT) keeps every tile-base on a 512-byte boundary
in DRAM, mirroring the 64-byte-aligned TMEM bases. Host-side
`compute_tmem_layout()` is responsible for picking 64-byte-aligned
TMEM `lmem_*buf{0,1}_base` values; HW does no fix-up.

**Consequence — kernel DMA is 1D, not 2D.** Because each tile is one
contiguous byte run, the kernel-issued `OP_DMA_LD` / `OP_DMA_ST` is
**single-segment**: one segment of `seg_size = total tile bytes`,
loop count `bound = 1`. There is no row/column inner-loop in HW; the
DMA engine just transfers `seg_size` bytes from `src_base` to
`dst_base` (with HBM-channel routing handled internally by
`VX_gemm_tmem_dma_ctrl`). The 2D burst-reorder form is reserved in
the cmd struct (`stride` field exists) but is **not implemented** for
kernel-issued DMAs on this branch — `VX_gemm_tmem_dma_ctrl.sv:472`
asserts `cmd.bound == 16'd1` for `OP_DMA_LD` / `OP_DMA_ST`.

This drives the FSM emit contract:

| Field          | Kernel DMA_LD/ST               |
|----------------|--------------------------------|
| `instr[3:0]`   | opcode (`OP_DMA_LD`/`ST`)      |
| `instr[31:4]`  | **`seg_size` = total tile bytes** (e.g. `mt_eff × kt_eff × FP16_BYTES` for input) |
| `bound[15:0]`  | **`16'd1`** (single segment)   |
| `stride[31:0]` | reserved (HW does not consume for the 1D path) |
| `rs1_data`     | dst base (TMEM for LD, DRAM for ST) |
| `rs2_data`     | src base (DRAM for LD, TMEM for ST) |

The fpint FSM was designed for a 2D form (`eff_mt = row count`,
implicit per-row stride). When porting, the row count must NOT be
remapped to `bound` — instead it is folded into `seg_size` (already
done in fpint's tile-byte computations like
`mt_eff*kt_eff*FP16_BYTES`), and `bound` is hard-set to `1`.

### 2.4 Test apps (canonical for this task)

Two `fpint_*` regression apps coexist:

| App                                | Driver style    | Role in this task |
|------------------------------------|------------------|-------------------|
| `tests/regression/fpint_gemm_ffn_hw/`         | **MMIO config-reg** (job_write_reg32 / gemm_job_alloc_fixed) | **Modified target.** Host (`main.cpp`, `common.h` kargs) is rewritten to mirror `_improve`'s layout (per §4.4); MMIO `kernel.cpp` driver is kept and adapted to the new kargs field names. |
| `tests/regression/fpint_gemm_ffn_hw_improve/` | **Cmd-stream** (stream_send / build_*_cmd) | **Read-only reference.** Source of truth for the TMEM 512B-aligned layout, `vx_mem_alloc_aligned(..., 512, ...)` DRAM allocation, slot-based scale/zp DRAM conversion, and `kernel_arg_t` field shape. We reuse this layout into `fpint_gemm_ffn_hw/` but never modify the `_improve` files. |

The current `fpint_gemm_ffn_hw/main.cpp` (pre-task) uses 64B alignment
and naive row-major scale/zp DRAM, which violates §2.3's per-tile
address constraints. Adopting `_improve`'s layout is the source-fix
required by Decisions #7 and #8 (no consumer-RTL relaxation, no
infra hacks). See §4.4 for the directive.

`fpint_gemm_ffn_hw_improve/*` is **never modified** by this task.

## 3. Decisions (locked)

| # | Question                                        | Decision                                                                 |
|---|-------------------------------------------------|--------------------------------------------------------------------------|
| 1 | TMEM/buffer sizing under runtime MT/KT/NT       | Host-side `compute_tmem_layout()` sizes TMEM exactly per (MT,KT,NT). HW does no bounds check. SW guarantees no overflow. |
| 2 | MT/KT/NT encoding in MMIO                       | Programmer writes `log2(MT)`, `log2(KT)`, `log2(NT)`. MT/KT/NT are pow2 only. HW reconstructs via `<< log2_X`.            |
| 3 | QDIR / WTRANS runtime coverage                  | Inherit fpint FSM as-is; QDIR and WTRANS are already cfg-driven. No FSM-side extension.                                  |
| 4 | Migration strategy                              | Wholesale: replace cmd-stream path with FSM path on the active datapath. **Cmd-stream RTL stays in tree** (cmd_constructor, VX_gemm_job_frontend, gemm_ctrl_with_ldma) — see §4.5 "no deletion" policy. They become orphaned but preserved.        |
| 5 | MXU_KT / MXU_NT                                 | Stay as compile-time `define`s (datapath width is fixed).                                                                |
| 6 | Modification scope                              | **RTL** (`hw/rtl/**`) and **kernel/test apps** (`tests/regression/<app>/**`, `kernel/**`) **only**. Sim TB harness, XRT runtime, sim wrappers, `.envrc`, etc. are off-limits. See §4.1.                                                                |
| 7 | DMA misalignment policy                         | **`ENABLE_MISALIGN = 0` is forced for every DMA / LDMA instance.** The HW alignment assertions (e.g. `VX_lmem_dma_misal.sv:165` 64-byte check) must NOT be relaxed. Any misalignment failure is a real bug — fix at the source (FSM stride/base computation or kernel-side TMEM layout), never by enabling misaligned mode. |
| 8 | RTL modification scope (within CMD path only)  | We only modify the **CMD-generation** side: `VX_gemm_fsm.sv` (CMD producer), the cmd struct typedef, and the glue logic inside `VX_gemm_ctrl.sv` / `VX_gemm_node.sv` that wires cmd fields onto each consumer module's interface. **CMD-consuming modules are off-limits** (`VX_gemm_sync.sv`, `VX_gemm_dma_ctrl.sv`, `VX_gemm_tmem_dma_ctrl.sv`, `VX_lmem_dma_misal.sv`, DMA engines, TMEM subsystem, MXU LDMA modules, etc.). See §4.2. |

## 4. Implementation Constraints

This section consolidates all locked constraints on what we may modify
and how. Decisions #4, #6, #7, #8 in §3 are summary pointers; the full
rules live here. **All sub-sections are non-negotiable** unless the
user explicitly relaxes them in the conversation.

### 4.1 File modification scope

#### Allowed

- **RTL — CMD-generation side only** (see §4.2 for the producer/consumer split):
  - `hw/rtl/core/gemm/VX_gemm_fsm.sv` (CMD producer)
  - `hw/rtl/core/gemm/VX_gemm_fsm_if.sv` (FSM ↔ ctrl interface)
  - `hw/rtl/core/gemm/VX_gemm_ctrl.sv` (parent FIFO, sync wiring, queues)
  - `hw/rtl/core/gemm/VX_gemm_node.sv` (glue logic that fans cmd fields onto consumer interfaces)
  - `hw/rtl/VX_gpu_pkg.sv` (`gemm_unified_cmd_t` typedef)
  - `hw/rtl/VX_config.vh` (defines)
- **Kernel / test apps**: `tests/regression/fpint_gemm_ffn_hw/**`, `kernel/**`
- **Unit tests**: `hw/unittest/**` — modify existing unittests when changing the corresponding RTL, or create a new `hw/unittest/<new>/` folder per the Verification Constraints below.
- **Documentation**: `docs/**`, `agent-tasks/**`, `harness/rules/**`

#### Off-limits — infra files

| File / dir                              | Why off-limits                                                  |
|-----------------------------------------|-----------------------------------------------------------------|
| `.envrc`                                | Project-wide env / CONFIGS contract; user-owned; shared across every backend (simx / rtlsim / xrt-vcs-sim). |
| `sim/xrtsim_vcs/tb_vcs_xrtsim.sv`       | VCS co-sim TB harness — shared contract across branches/tasks.  |
| `sim/xrtsim_vcs/Makefile`               | Build flow contract; do not add RTL deps to work around staleness. |
| `runtime/xrt/vortex.cpp`                | XRT host driver — shared by every XRT-backed test.              |
| `runtime/**` (other backends)           | Same reasoning.                                                 |
| `sim/simx/**`, `sim/rtlsim/**`          | Simulator wrappers; not within this task's contract.            |
| `ci/**`, `harness/hooks/**`             | CI / harness glue.                                              |
| `tests/regression/fpint_gemm_ffn_hw_improve/**` | Cmd-stream baseline — read-only reference (see §4.4). |

#### Forbidden infra workarounds

- **Do NOT** edit `.envrc` to add/remove/escape CONFIGS for any reason — quoting bugs, value overrides, debug defines, anything. The user owns this file. If a CONFIGS change is genuinely required, STOP and report.
- **Do NOT** `touch` an infra source file to force `simv` rebuild after an RTL change. The simv Makefile (per `harness/rules/sim-common.md`) intentionally lists only TB/DPI deps. The correct response is `make -C sim/xrtsim_vcs clean` and rebuild.
- **Do NOT** modify the TB harness to add visibility (`$display`, probe ports). Add `\`ifdef DBG_TRACE_*` blocks **inside the RTL** instead, then re-run with the corresponding define enabled (`harness/rules/sim-common.md`).
- **Do NOT** modify the XRT runtime to bypass an MMIO/DMA contract bug. Fix it in RTL or in `kernel.cpp`.

If you hit an infra-side blocker that genuinely cannot be solved within scope (e.g., a runtime API really is broken for this branch's RTL), **STOP and report**. Don't silently broaden the change scope.

### 4.2 RTL modification scope — within CMD path only

`gemm_unified_cmd_t` is the bus between the FSM (producer) and the
downstream consumers. We modify the **producer side and the glue that
fans cmd fields onto each consumer's interface only**. Consumer
modules are off-limits.

#### Off-limits RTL — CMD consumers

| Module / dir                                  | Why off-limits                                                |
|-----------------------------------------------|---------------------------------------------------------------|
| `hw/rtl/core/gemm/VX_gemm_sync.sv`            | CMD consumer — opcode routing to child paths.                 |
| `hw/rtl/core/gemm/VX_gemm_dma_ctrl.sv`        | CMD consumer — DRAM ↔ LMEM DMA executor.                      |
| `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv`   | CMD consumer — DRAM ↔ TMEM DMA executor (asserts `bound==1`). |
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv`       | CMD consumer — LMEM/TMEM DMA with `ENABLE_MISALIGN=0` check.  |
| `hw/rtl/core/gemm/VX_cmd_constructor.sv`      | Orphaned in FSM-based design but preserved per §4.5.          |
| `hw/rtl/core/gemm/VX_gemm_job_frontend.sv`    | Cmd-stream legacy frontend; orphaned per §4.5.                |
| `hw/rtl/core/gemm/VX_gemm_ctrl_with_ldma.sv`  | Legacy monolithic variant; orphaned per §4.5.                 |
| MXU LDMA modules, DMA engine, TMEM subsystem, tensor-mem banks, MXU datapaths, FPU, cache hierarchy, etc. | Outside the CMD-generation boundary. |
| All `*_if.sv` interfaces consumed by the above (`VX_gemm_ctrl_if`, `VX_gemm_sync_if`, `VX_lmem_dma_ctrl_if`, etc., **except** `VX_gemm_fsm_if`) | These are stable contracts; field set/widths are fixed. |

#### Forbidden RTL workarounds

- **Do NOT** modify a CMD-consumer module to "accept" a cmd field shape that the FSM emits. Fix the FSM emit (or the gemm_node glue that maps cmd fields onto the consumer's interface) instead.
- **Do NOT** add new opcodes that require `VX_gemm_sync.sv` / `VX_cmd_constructor.sv` decode changes. Reuse the existing 4-bit opcode set listed in `VX_gemm_sync.sv:25-33` and the `RAW_OP_*` set in `VX_cmd_constructor.sv:16-24`.
- **Do NOT** widen / narrow `gemm_unified_cmd_t` field bit-widths in a way that breaks consumer decode logic. Field shape is fixed by `VX_cmd_constructor.sv`'s decode (`{tmem_stride16, mxu_stride16}` for QPARAM, `{16'd0, stride16}` for others).
- **Do NOT** modify `VX_lmem_dma_misal.sv`'s 64-byte alignment assertion or the `VX_gemm_tmem_dma_ctrl.sv:472` / `:487-493` assertions. Any failure is a real bug to fix in FSM stride/base emit (per §4.3) or kernel TMEM layout (per §4.4).

If the failure is genuinely on the CMD-consumer side and CANNOT be fixed by changing what the FSM emits or how gemm_node glue routes the fields, **STOP and report**. Don't silently expand RTL scope into the consumer modules.

### 4.3 DMA / alignment policy

**`ENABLE_MISALIGN = 0` is forced for every DMA / LDMA instance.** The
HW alignment assertions must NOT be relaxed:

- `VX_lmem_dma_misal.sv:165` — 64-byte alignment of `src_base` / `dst_base`.
- `VX_gemm_tmem_dma_ctrl.sv:472` — `bound == 16'd1` for kernel `OP_DMA_LD` / `OP_DMA_ST` (1D form, see §2.3).
- `VX_gemm_tmem_dma_ctrl.sv:487-493` — channel-slot match (`HBM_addr[8:6] == TMEM_addr[8:6]`).

Any misalignment failure is a **real bug** to fix at the source — either in the FSM stride/base emit (CMD-generation side, allowed by §4.2) or in the kernel-side TMEM layout (allowed by §4.4) — never by enabling misaligned mode or weakening assertions.

The per-tile address constraints driving these assertions are enumerated in §2.3 (`HBM_addr % 64 == 0`, `TMEM_addr % 64 == 0`, `HBM_addr % 512 == TMEM_addr % 512`). They apply per-tile, not just per-matrix.

### 4.4 SW host reuse — `fpint_gemm_ffn_hw_improve/main.cpp`

**Locked directive:** `tests/regression/fpint_gemm_ffn_hw/main.cpp` (host driver) MUST be replaced by the structure of `tests/regression/fpint_gemm_ffn_hw_improve/main.cpp` — that file is the canonical TMEM/DRAM-aware layout reference. Do NOT keep the existing `fpint_gemm_ffn_hw/main.cpp`'s ad-hoc 64-byte-aligned layout.

**Why:** the `_improve` host satisfies §2.3's per-tile address constraints by construction:

1. `vx_mem_alloc_aligned(..., DRAM_ALIGN_BYTES=512, ...)` for every DRAM buffer (input / weight / scale / zp / output) — every tile's HBM base ends on a 512B boundary.
2. `TMEM_LAYOUT_ALIGN_BYTES=512` in `compute_tmem_layout()` — every `lmem_*buf{0,1}` TMEM base is 512B-aligned. Combined with (1), `HBM_addr % 512 == TMEM_addr % 512 == 0` holds for every tile.
3. **Tiled DRAM conversion** (`convert_input_tiled` / `convert_weight_tiled`) plus slot-based `convert_scale_tiled` / `convert_zp_tiled` with `scale_slot_bytes()` 512B padding — each MXU sub-tile lands at a 512B-aligned position inside the tile.

The current `fpint_gemm_ffn_hw/main.cpp` uses 64B alignment + naive row-major scale/zp DRAM, violating constraint #3. Adopting `_improve`'s layout fixes this at the SOURCE; relaxing HW assertions (forbidden by §4.3) or modifying CMD-consumer modules (forbidden by §4.2) are NOT acceptable substitutes.

The `_improve` test app itself is **read-only** (per §4.1). We copy/adapt its layout patterns into `fpint_gemm_ffn_hw/`, but we never modify files under `tests/regression/fpint_gemm_ffn_hw_improve/`.


### 4.5 No-deletion policy

The cmd-stream RTL is **kept in tree** after migration:

- `hw/rtl/core/gemm/VX_cmd_constructor.sv` — preserved.
- `hw/rtl/core/gemm/VX_gemm_job_frontend.sv` — preserved.
- `hw/rtl/core/gemm/VX_gemm_ctrl_with_ldma.sv` — preserved.
- `hw/unittest/cmd_constructor/` and other cmd-stream TBs — preserved.
- `RAW_OP_*` constants — preserved.

These modules become orphaned (no consumer in the active datapath) but remain available for fall-back debug or future re-use. Removal is deferred to a separate, explicit cleanup task once the FSM-based path has soaked through silicon validation.

# Verification Constraints
- First, succeed unittest verification if you change rtl. find proper folder at hw/unittest and if there is not, make new one.
- After succeed necessary unittests, run regression test. Following next instructions
  - cd to build/
  - run ../configure
  - run make -C sim clean; make -C runtime clean if you change anything
  - run ../ci/run_black.py with xrt-vcs-sim driver, app=fpint_gemm_ffn_hw. For example python ../ci/run_black.py xrt-vcs-sim --app=fpint_gemm_ffn_hw --args="-m 128 -k 128 -n 128". Test with various args