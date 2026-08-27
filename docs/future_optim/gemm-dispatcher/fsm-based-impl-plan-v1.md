# GEMM Dispatcher Optimization — FSM-Based Implementation Plan (v1)

This is the **execution side** of the FSM-based GEMM dispatcher
migration. It assumes the reader has already read the situation +
constraints document:

- `docs/gemm-dispatcher-optim/fsm-based.md` (problem recap, fpint
  analysis, current branch state, decisions, **Implementation
  Constraints §4**).

All section references with the form `fsm-based.md §X.Y` point into
that companion doc. Constraints in `fsm-based.md §4` are non-negotiable
unless the user explicitly relaxes them in conversation.

## 1. Implementation plan

### 1.1 Config-register layout extension

**Pre-flight discovery**: `\`GEMM_FSM_MT`, `\`GEMM_FSM_KT`,
`\`GEMM_FSM_NT`, `\`GEMM_FSM_MXU_KT`, `\`GEMM_FSM_MXU_NT` are
referenced by `hw/rtl/core/gemm/VX_gemm_fsm.sv:198-204` (the dormant
copy merged from `fpint`) but are **not defined anywhere on
`fpint_improve`**. The dormant module therefore does not elaborate
today. SKELETON must add these defines at their fpint values so the
dormant lint passes; IMPLEMENT then retires the MT/KT/NT defines (the
MXU_* defines stay).

```verilog
// SKELETON: add to hw/rtl/VX_config.vh
`define GEMM_FSM_MT     128
`define GEMM_FSM_NT     128
`define GEMM_FSM_KT     128
`define GEMM_FSM_MXU_KT 32
`define GEMM_FSM_MXU_NT 32
```

Then extend `GEMM_CFG_REG_NUM` from 40 → **43** and add three slots in
`hw/rtl/VX_config.vh`:

```
 40  LOG2_DMA_MT     (5b used; programmer writes log2(MT), e.g. 7 for MT=128)
 41  LOG2_DMA_KT
 42  LOG2_DMA_NT
```

Also add a compile-time **upper bound** define so we can size data
widths and loop bound counters:

```verilog
`define GEMM_FSM_LOG2_MT_MAX 8   // MT_max = 256, baseline 128 (LOG2=7)
`define GEMM_FSM_LOG2_KT_MAX 8
`define GEMM_FSM_LOG2_NT_MAX 8
// retire `GEMM_FSM_MT, `GEMM_FSM_NT, `GEMM_FSM_KT (no longer compile-time)
```

Picking MAX=8 (not 7) gives one bit of headroom — sync register
strides and counter widths are sized off `LOG2_*_MAX`, so anything
the SW programs into the cfg reg up to `log2=8` (=256) is legal at
runtime. The current default workload uses MT=KT=NT=128 (`LOG2=7`).

These maxes determine the worst-case sync-register stride
(`MXU_PER_TILE_MAX`) and tile-coordinate counter widths (`mm_dim_t`,
`mm_tile_sz_t`). MXU_KT / MXU_NT remain as compile-time defines.

### 1.2 SW updates — reuse-vs-adapt details

The directive ("MUST reuse `_improve/main.cpp`") and rationale live in
`fsm-based.md §4.4`. This subsection captures the technical breakdown.

#### What gets reused vs. what gets adapted

| Layer                                                 | Source                                           | Action |
|-------------------------------------------------------|--------------------------------------------------|--------|
| `main.cpp` host: build_test_vectors, convert_*_tiled, compute_tmem_layout, allocations, uploads, verify_results_tiled | `fpint_gemm_ffn_hw_improve/main.cpp`            | **Reuse verbatim** (re-target to MMIO kargs struct field names) |
| `common.h` `kernel_arg_t` field shape (`dram_*_base`, `lmem_*[2]` arrays, M/N/K/QBLK/WTRANS/QDIR, status) | `fpint_gemm_ffn_hw_improve/common.h`             | **Reuse verbatim**, then **add** MMIO-only fields: `LOG2_DMA_MT/KT/NT`, `job_eid`, `job_generation`, `last_ctrl` |
| `common.h` MMIO register map (REG_*, GEMM_JOB_NUM_REGS32, status codes) | (MMIO-specific — keep as-is from current `fpint_gemm_ffn_hw/common.h`) | **Keep** |
| `kernel.cpp` MMIO driver (gemm_job_alloc_fixed, program_job_regs, wait_job_done) | (MMIO-specific — current `fpint_gemm_ffn_hw/kernel.cpp`) | **Adapt** field names from `arg->input_base` → `arg->dram_in_base`, `arg->lmem_ibuf0_base` → `arg->lmem_ibuf[0]`, etc., then keep the MMIO programming logic as-is |

#### `_improve` is still NOT modified

The `_improve` test app is a **read-only reference** (per
`fsm-based.md §4.1` / §4.4). We copy/adapt its layout patterns into
`fpint_gemm_ffn_hw/`, but we never touch files under
`tests/regression/fpint_gemm_ffn_hw_improve/`.

#### MMIO-specific extension on top of reused `_improve` host

After the reuse + adapt above, `program_job_regs()` in
`fpint_gemm_ffn_hw/kernel.cpp` writes the three new log2 registers
before `REG_CONTROL`:

```c
job_write_reg32(eid, REG_LOG2_DMA_MT, log2_pow2_u32(DMA_MT));
job_write_reg32(eid, REG_LOG2_DMA_KT, log2_pow2_u32(DMA_KT));
job_write_reg32(eid, REG_LOG2_DMA_NT, log2_pow2_u32(DMA_NT));
job_write_reg32(eid, REG_CONTROL, 1u);
```

(`DMA_MT/KT/NT` are compile-time constants in `_improve`'s `main.cpp`
— pass them through `kernel_arg_t.LOG2_DMA_*` to the kernel.)

### 1.3 RTL updates — `VX_gemm_node.sv`

Replace the frontend block in `hw/rtl/core/gemm/VX_gemm_node.sv:379`:

```diff
- VX_gemm_job_frontend #(
-   .INSTANCE_ID(INSTANCE_ID),
-   .NUM_MASTERS(N_MASTER),
-   .CFG_BASE_ADDR(`GEMM_REG_BASE_ADDR)
- ) u_gemm_job_frontend (
-   .clk(clk),
-   .reset(reset),
-   .mmio_if(mmio_if),
-   .issue_if(issue_if),
-   .done_if(done_if)
- );
+ VX_config_reg_if #(.NUM(`GEMM_CFG_REG_NUM), .DW(32)) issue_if();
+ VX_job_frontend #(
+   .INSTANCE_ID(INSTANCE_ID),
+   .NUM_MASTERS(N_MASTER),
+   .NUM_ENTRIES(NUM_ENTRIES),
+   .NUM_REGS32(`GEMM_CFG_REG_NUM),
+   .CFG_BASE_ADDR(`GEMM_REG_BASE_ADDR)
+ ) u_job_frontend (
+   .clk(clk), .reset(reset),
+   .mmio_if(mmio_if),
+   .issue_if(issue_if),
+   .done_if(done_if)
+ );
```

Replace `issue_if` declaration (currently `VX_instruction_if`) with
`VX_config_reg_if` of width `GEMM_CFG_REG_NUM × 32`.

Change the `VX_gemm_ctrl` instantiation (line 528) to bind
`cfg_reg_if(issue_if)` instead of `instruction_if(issue_if)`.

### 1.4 RTL updates — `VX_gemm_ctrl.sv` swap

Fetch the cfg-driven version directly from git (do **not** rely on
`/tmp` snapshots, which can be lost):

```bash
git show fpint:hw/rtl/core/gemm/VX_gemm_ctrl.sv > \
    hw/rtl/core/gemm/VX_gemm_ctrl.sv
```

Then patch the imported copy:

- Use current branch's `VX_STATIC_ASSERT` macro (line 1823–1825 of
  `VX_gemm_fsm.sv`) instead of fpint's `STATIC_ASSERT`.
- Drop `gemm_unit_computing` perf input (current ctrl uses it; fpint
  ctrl uses `job_active_q`; pick fpint's semantics).
- Keep `gemm_node_done_if` master direction; the new `done_if` is
  driven by `job_active_q` + `all_idle_now` (fpint convention) rather
  than by sync's `flag.done` (cmd-stream convention).

### 1.5 RTL updates — `VX_gemm_fsm.sv` MT/KT/NT MMIO-fication

This is the new work beyond fpint. Edit
`hw/rtl/core/gemm/VX_gemm_fsm.sv`:

1. **Replace `localparam` with cfg-driven regs**:
   ```diff
   - localparam int MT = `GEMM_FSM_MT;
   - localparam int NT = `GEMM_FSM_NT;
   - localparam int KT = `GEMM_FSM_KT;
   + // Latched at start; widths sized by *_MAX defines.
   + logic [`GEMM_FSM_LOG2_MT_MAX:0] MT_q, MT_d;
   + logic [`GEMM_FSM_LOG2_KT_MAX:0] KT_q, KT_d;
   + logic [`GEMM_FSM_LOG2_NT_MAX:0] NT_q, NT_d;
   + logic [$clog2(`GEMM_FSM_LOG2_MT_MAX+1)-1:0] LOG2_MT_q;
   + logic [$clog2(`GEMM_FSM_LOG2_KT_MAX+1)-1:0] LOG2_KT_q;
   + logic [$clog2(`GEMM_FSM_LOG2_NT_MAX+1)-1:0] LOG2_NT_q;
   ```
2. **Add cfg-reg indices**:
   ```verilog
   localparam int CFG_R_LOG2_DMA_MT = 40;
   localparam int CFG_R_LOG2_DMA_KT = 41;
   localparam int CFG_R_LOG2_DMA_NT = 42;
   ```
3. **Latch on start**:
   ```verilog
   if (cfg_start_fire) begin
     LOG2_MT_q <= cfg_reg_if.regs[CFG_R_LOG2_DMA_MT][LOG2_W-1:0];
     LOG2_KT_q <= cfg_reg_if.regs[CFG_R_LOG2_DMA_KT][LOG2_W-1:0];
     LOG2_NT_q <= cfg_reg_if.regs[CFG_R_LOG2_DMA_NT][LOG2_W-1:0];
     MT_q <= 1 << cfg_reg_if.regs[CFG_R_LOG2_DMA_MT][LOG2_W-1:0];
     KT_q <= 1 << cfg_reg_if.regs[CFG_R_LOG2_DMA_KT][LOG2_W-1:0];
     NT_q <= 1 << cfg_reg_if.regs[CFG_R_LOG2_DMA_NT][LOG2_W-1:0];
   end
   ```
4. **Convert all `MT/KT/NT` use sites to shifts** (since pow2):
   - Line 435–437 `mt_eff = (mt == ...) ? *_last_q : MT` → unchanged
     except `MT` is now `MT_q`. (Comparisons on `mm_dim_t` still work.)
   - Line 467, 472, 476: `nt * NT >> 1` → `(nt << LOG2_NT_q) >> 1`.
   - Line 669–671: `target_M & (MT - 1)` → `target_M & (MT_q - 1)`.
     (The `MT_q - 1` mask is correct for any pow2 `MT_q`.)
   - Line 868: `n0_out * MT * FP32_BYTES` → `n0_out << (LOG2_MT_q + 2)`.
   - Lines 876–877, 898–899: `NT * FP16_BYTES` → `1 << (LOG2_NT_q + 1)`.
   - Tile-address functions (444–533, 657 onwards): all `MT*KT*2`,
     `(KT*NT)/2`, `groups_full*NT*2`, `MT*NT*2` strides become shift
     compositions.
5. **Worst-case sync stride**: `MXU_PER_TILE_MAX` (line 306-308) is
   computed from `KT/NT`. Replace with the **MAX** form:
   ```verilog
   localparam MXU_N_PER_TILE_MAX = ((1 << `GEMM_FSM_LOG2_NT_MAX) + `GEMM_FSM_MXU_NT - 1)
                                   >> `CLOG2(`GEMM_FSM_MXU_NT);
   localparam MXU_K_PER_TILE_MAX = ((1 << `GEMM_FSM_LOG2_KT_MAX) + `GEMM_FSM_MXU_KT - 1)
                                   >> `CLOG2(`GEMM_FSM_MXU_KT);
   ```
   (i.e. size sync registers for the worst-case tile, run with current
   stride at runtime.) **Area cost**: with `LOG2_*_MAX = 8` and
   `MXU_KT = MXU_NT = 32`, `MXU_PER_TILE_MAX` becomes
   `(256/32) × (256/32) = 64`, vs the prior `(128/32) × (128/32) = 16`
   — a **4× growth** in sync register storage and the indexer width
   for `tile_mxu_base = tile_cur_q * MXU_PER_TILE_MAX`. If this area
   cost is unacceptable, drop `LOG2_*_MAX` to 7 (matches today's
   baseline; gives no headroom for future >128 tiles).
6. **CHIPSCOPE probes**: add `LOG2_MT_q/KT_q/NT_q` to debug probe2;
   bump `DBG_GEMM_P*_W` and adjust `VX_STATIC_ASSERT` checks at lines
   1823–1825.

A full audit of MT/KT/NT use sites in fpint's `VX_gemm_fsm.sv` (from
`/tmp/fpint_gemm_fsm.sv`) gives **~30 individual occurrences** across
the address-gen functions, the `*_last_q` masks, and the LMEM stride
computations. All are straightforward `* X` → `<< log2_X` rewrites
under the pow2 invariant.

### 1.6 Cmd struct remap — fpint FSM → fpint_improve fields (option A)

**Critical discovery**: `gemm_unified_cmd_t` is **different** between
the two branches. This means the fpint FSM's emit code cannot be
ported verbatim — its output fields must be remapped to the
fpint_improve struct.

| Field                    | fpint                | fpint_improve        |
|--------------------------|----------------------|----------------------|
| `instr`                  | `[31:0]`             | `[31:0]` (same — opcode in [3:0], size/acc_cnt in [31:4]) |
| `rs1_data`, `rs2_data`   | `[XLEN-1:0]`         | `[XLEN-1:0]` (same) |
| `flags`                  | `[7:0]`              | `[7:0]` (same)       |
| `eff_mt`                 | `[20:0]` ★          | — (does not exist)   |
| `groups_eff`             | `[31:0]` ★          | — (does not exist)   |
| `stride`                 | —                    | `[31:0]` ★          |
| `bound`                  | —                    | `[15:0]` ★          |

★ = present in only one branch.

**Where the data goes (fpint_improve consumers — verify-by-trace):**

- `cmd.bound[15:0]` —
  - **Kernel DMA_LD/DMA_ST: hard-set to `16'd1`** (1D form, see
    `fsm-based.md §2.3` "tile-contiguous DRAM layout").
    `VX_gemm_tmem_dma_ctrl.sv:472` enforces this with
    `assert (cmd.bound == 16'd1) else $fatal(...)`.
  - **MXU_LOAD_*** cmds: loop/segment count consumed by
    `VX_cmd_constructor.sv:179,196,220,235`.
- `cmd.instr[31:4]` — for `RAW_OP_DMA_LD/ST` carries `seg_size` (=
  **total tile bytes**, since `bound=1`); for `RAW_OP_MXU_LOAD_INPUT`
  carries `acc_cnt[27:0]`. fpint's `eff_mt × per_row_bytes` and
  `groups_eff × per_group_bytes` are folded into `seg_size` via the
  existing `mt_eff*kt_eff*FP16_BYTES`-style expressions in fpint's
  tile-bytes computation; nothing else of `eff_mt` lands here.
- `cmd.stride[31:0]` —
  - **Kernel DMA_LD/DMA_ST**: reserved/unused on this branch — the
    1D form does not consume it. Reserved for a future 2D
    burst-reorder extension (already named in
    `VX_gemm_tmem_dma_ctrl.sv` comments) but not implemented.
  - **MXU_LOAD_*** cmds: per `VX_cmd_constructor.sv`:
    - `RAW_OP_MXU_LOAD_WEIGHT`: `{16'd0, stride16}` (line 178).
    - `RAW_OP_MXU_LOAD_QPARAM`: `{tmem_stride16, mxu_stride16}` (line
      195) — split form.
    - `RAW_OP_MXU_LOAD_INPUT`: `{16'd0, stride16}` (line 219).
    - `RAW_OP_MXU_STORE_OUTPUT`: `{16'd0, stride16}` (line 234).
- `cmd.flags[7:0]` — buf_sel / qdir / wtrans / is_accum / is_last,
  same bit-meaning as fpint.

**Required port work** (per cmd type emitted by fpint FSM):

1. **`out_cmd_d.eff_mt = X`** sites:
   - For DMA_LD/DMA_ST (kernel DMAs): **delete the assignment** —
     `eff_mt` was the row count in fpint's 2D form; on this branch it
     is implicit in `seg_size` (`make_dma_ld(..., total_bytes, ...)`
     already takes `mt_eff*kt_eff*FP16_BYTES`-style total bytes).
     `bound` stays `16'd1`.
   - For MXU_LOAD_INPUT (`OP_I_LDMA_ARM`): map to
     `out_cmd_d.instr[31:4]` (acc_cnt path).
2. **`out_cmd_d.groups_eff = X`** sites:
   - For DMA_LD/DMA_ST: **delete the assignment** (same reasoning —
     folded into `seg_size`, kernel DMA is 1D, `bound=1`).
   - For MXU cmds where the consumer expects a per-cmd loop count
     (`OP_W_LDMA_MXU` etc.): map to `out_cmd_d.bound`.
3. **Add stride emit** (new logic). fpint FSM has no stride emitter
   because fpint's gemm_node hard-codes strides at `KT*16/8` etc.
   On fpint_improve:
   - **MXU_LOAD_*** cmds: pack `cmd.stride` per the
     `VX_cmd_constructor.sv` decode listed above
     (typically `MXU_KT*BPE` or `MXU_NT*BPE`).
   - **Kernel DMA_LD/DMA_ST**: stride is reserved (1D form). The
     FSM may set it for documentation/future use but the HW does not
     consume it. Setting `cmd.stride = (1 << LOG2_KT_q) * 2` etc. is
     harmless but optional.

The grep audit at IMPLEMENT must enumerate every `out_cmd_d.*`
write site in the imported FSM and apply the corresponding remap.

**Why option A over B**: fpint_improve's `VX_gemm_node` is already
wired to consume `cmd.stride` / `cmd.bound`. Option B (route cfg
into gemm_node) would require unwiring all those existing consumers
and re-deriving stride locally — much larger diff.

### 1.7 Update `harness/rules/rtl-arch.md`

The branch arch rule today says:

> HW does not compute addresses, strides, or bounds — these are passed
> through from the SW-encoded command

This is **inverted** by this plan. Update to:

> The GEMM FSM (`VX_gemm_fsm`) computes addresses, strides, and bounds
> in HW from the cfg_reg snapshot. SW writes a 43-register job
> descriptor; HW emits the unified cmd stream.

## 2. Verification plan

### 2.0 Test commands (canonical)

All regression invocations run from the `build/` directory:

```bash
# Default vcs co-sim with -m 512 -k 128 -n 128:
python ../ci/run_black.py xrt-vcs-sim --app=fpint_gemm_ffn_hw \
    --args="-m 512 -k 128 -n 128" --perf=3

# Clean rebuild (only when sim/runtime artifacts go stale, e.g. after a
# config or define change that the incremental build misses):
make -C sim clean
make -C runtime clean
```

`fpint_gemm_ffn_hw` (no `_improve`) is the canonical app for this task;
it already drives the MMIO config-reg path.

### 2.1 Unit-level

1. `hw/unittest/gemm_fsm/` already exists (TB
   `tb_VX_gemm_fsm.sv`) — extend it to drive `LOG2_DMA_MT/KT/NT` from
   the cfg snapshot and sweep:
   - (LOG2_MT, LOG2_KT, LOG2_NT) ∈ {(7,7,7), (6,7,7), (7,6,7),
     (7,7,6), (6,6,6)}.
   - For each, capture the emitted cmd trace and check it matches a
     golden Python reference (the FSM emit sequence is deterministic).

2. `hw/unittest/gemm_node/` (canonical TB) — re-run after wholesale
   switchover. The TB already programs cfg regs directly using
   `JOB_NUM_REGS32 = GEMM_CFG_REG_NUM` — once the DUT is updated to
   instantiate `VX_job_frontend`, TB and DUT will be aligned. The
   `gemm_node_improve` and `gemm_node_tmem` TB variants are **out of
   scope** for this task.

### 2.2 Integration

3. `tests/regression/fpint_gemm_ffn_hw/`: run via the §2.0 command at
   default `-m 512 -k 128 -n 128`. Bit-exact output expected.

4. Add a sweep pinning M=N=K=512 and varying
   `(LOG2_MT, LOG2_KT, LOG2_NT)`:
   - `(7,7,7)` baseline (128 each)
   - `(6,7,7)`, `(7,6,7)`, `(7,7,6)` (one dim halved)
   - `(6,6,6)` (all halved)
   - `(7,8,7)` (KT doubled — gated by `LOG2_*_MAX = 8`; optional)

   The sweep is exposed by passing `LOG2_DMA_*` overrides through
   `kernel_arg_t` (or compile-time defines) to `kernel.cpp`'s
   `program_job_regs`.

### 2.3 Performance verification

5. On `vcs_cosim`, capture FSDB and compare:
   - **Baseline** (cmd-stream): MMIO store count over the GEMM-occupied
     window from `tools/mmio_analysis/`.
   - **FSM**: same window, expect ~43 stores per job (one per cfg
     register) + 1 ALLOC read + N_poll reads for completion.
   - Total job latency (alloc → done handshake) should drop sharply on
     small problems (where the dispatcher dominated) and stay flat on
     large compute-bound problems.

6. Re-use the `tools/mmio_analysis/` and the perf-counter infra
   already in `VX_gemm_ctrl` (`perf_total_cycles_r`) to compare cycle
   counts head-to-head on identical workloads.

## 3. Risk register

| Risk                                                            | Likelihood | Mitigation                                                                          |
|-----------------------------------------------------------------|-----------:|-------------------------------------------------------------------------------------|
| Stale comments in fpint FSM mislead implementation              |     Medium | Treat the *RTL* as ground truth; the QDIR/WTRANS comment was already proven stale.  |
| MT/KT/NT shift conversion missed somewhere                      |       High | Grep audit list (~30 sites) is exhaustive; lint after edit; unit-test sweep of dims. |
| Sync register stride sized too small under MAX_KT=MAX_NT=256    |        Low | `MXU_PER_TILE_MAX` is sized off LOG2_*_MAX; just keep MAX consistent across files.   |
| Sync register area cost 4× at LOG2_*_MAX=8 vs 7                  |     Medium | If area is tight at synthesis, drop MAX to 7 (matches today's baseline, no headroom).|
| `tb_VX_gemm_node` TB/DUT mismatch on current HEAD                |     Medium | Run TB on HEAD before SKELETON; record current-HEAD pass/fail in STATUS as baseline. |
| fpint FSM cmd field set differs from fpint_improve struct        |       High | §1.6 enumerates the remap. For kernel DMA_LD/ST: `eff_mt`/`groups_eff` writes are **deleted** (already folded into `seg_size` via `make_dma_ld(..., total_bytes, ...)`), `bound = 16'd1` is hard-set per `fsm-based.md §2.3` (1D form). For MXU INPUT: `eff_mt`→`instr[31:4]` (acc_cnt). IMPLEMENT must grep audit every `out_cmd_d.*` write site in imported FSM. |
| Per-tile address alignment violations (`HBM%64`, `TMEM%64`, `HBM%512==TMEM%512`) | High | Forced at SW source by `_improve/main.cpp` reuse (`fsm-based.md §4.4`): `vx_mem_alloc_aligned(...,512,...)` for DRAM + `TMEM_LAYOUT_ALIGN_BYTES=512` + slot-based scale/zp DRAM. HW assertions (`VX_lmem_dma_misal.sv:165`, `VX_gemm_tmem_dma_ctrl.sv:472,487-493`) catch any violation; per `fsm-based.md §4.3` they must NOT be relaxed. |
| TMEM overflow under bad SW config                               |     Medium | Add a one-line `assert` in `compute_tmem_layout()` and an `$error` in TB.            |
| `VX_gemm_ctrl_with_ldma.sv` has hidden consumers                |        Low | Before removal, audit active instantiations plus RTL, unittest, synthesis, and packaging source lists; remove its dedicated test only with the orphaned module. |
| Job dispatcher arbitration assumes ≤16 entries                  |        Low | `JOB_MMIO_NUM_ENTRIES = 4` already; matches fpint.                                   |
| Gemm_node strides recomputed in two places (FSM + node)         |     Medium | Decision 4.6 (option A) eliminates the duplication: stride travels in the cmd.       |

## 4. Suggested implementation order

1. **Audit + define skeleton** (RTL only, no behavioural change yet)
   - Add `LOG2_DMA_*_MAX` defines to `VX_config.vh`, bump
     `GEMM_CFG_REG_NUM` to 43.
   - Confirm dormant FSM-path modules build (no changes yet).
2. **FSM MT/KT/NT MMIO-fication**
   - Latch `LOG2_*_q`, `*_q` from cfg.
   - Mechanical shift conversion of all `MT/KT/NT` use sites.
   - Cmd-struct remap per §1.6 (`eff_mt`/`groups_eff` deletes for DMA,
     `bound=16'd1` hard-set, `instr[31:4]=acc_cnt` for MXU INPUT).
   - Run `tb_VX_gemm_fsm` with `(7,7,7)` first.
3. **Switch gemm_node to FSM frontend**
   - Replace `VX_gemm_job_frontend` → `VX_job_frontend`.
   - Replace `VX_gemm_ctrl` (cmd-stream) → `VX_gemm_ctrl` (cfg-driven,
     fpint-port).
   - Move stride synthesis into FSM cmd's `stride` field for MXU
     LDMAs; kernel DMA_LD/ST uses `bound=1, instr[31:4]=seg_size`.
4. **SW host rewrite — reuse `_improve/main.cpp`** (per `fsm-based.md §4.4`)
   - Replace `fpint_gemm_ffn_hw/main.cpp` with `_improve/main.cpp`'s
     host structure: `vx_mem_alloc_aligned(...,512,...)`,
     `TMEM_LAYOUT_ALIGN_BYTES=512`, tiled DRAM conversion, slot-based
     scale/zp.
   - Refit `kernel_arg_t` to the `_improve` shape (`dram_*_base`,
     `lmem_*[2]` arrays); add MMIO-only fields (`LOG2_DMA_*`,
     `job_eid`, `job_generation`, `last_ctrl`).
   - Adapt `kernel.cpp`'s `program_job_regs()` to the new field
     names; add the three `LOG2_DMA_*` reg writes before
     `REG_CONTROL`.
   - Keep MMIO register map and status codes in `common.h`.
   - Do NOT modify `tests/regression/fpint_gemm_ffn_hw_improve/`.
5. **Unit-test sweep** (MT/KT/NT permutations on `tb_VX_gemm_fsm`).
6. **Integration sim on `fpint_gemm_ffn_hw`** (xrt-vcs-sim per §2.0).
   The `_improve` cmd-stream app is the prior baseline for perf
   comparison only — not the target of any sim re-verification here.
7. **Performance comparison** vs cmd-stream baseline.
8. **Update arch rules** (`harness/rules/rtl-arch.md`). cmd-stream RTL
   stays in tree; deletion is out of scope (Decision #4 +
   `fsm-based.md §4.5`).

## 5. Open items / future work

- DAE.md and "8-thread parallel MMIO burst" optimisations remain
  orthogonal: with FSM dispatch the per-job MMIO budget drops to ~43
  stores, which makes both follow-on optimisations less impactful but
  not redundant — DAE still helps when many small jobs queue up,
  burst-MMIO still helps the program-regs phase.
- Multi-job pipelining: `JOB_MMIO_NUM_ENTRIES = 4` allows up to 4
  concurrent job descriptors; the dispatcher picks one at a time
  today, but could be extended to overlap KT-loop of job N+1 with
  ACC2LMEM/store of job N.
- M_START/N_START are only meaningful for partitioned launches; the
  current SW always sets m_start=n_start=0. Keep them in the cfg
  layout for future per-TB partitioning (kernel.cpp already computes
  `tb_partition` → m_start/n_start).
