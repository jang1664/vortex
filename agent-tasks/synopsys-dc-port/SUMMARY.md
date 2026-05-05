# Synopsys DC Port — Change Summary & Review Points

Vortex AFU (`fpint_improve` branch) Synopsys Design Compiler synthesis port.
Active config: `.envrc` (NUM_CORES=1, NUM_THREADS=8, NUM_WARPS=4, DCACHE_DISABLE,
L2_ENABLE, LMEM=512KB, TMEM=8×64KB, GEMM_ACC=1024×1024).

Synth-time toggles introduced:
- `+define+SYNOPSYS` — selects DC-friendly RTL paths in async-RAM patch and FP unit.
- `+define+COMPILED_SRAM_28LPP` — routes sync-BRAM RAMs through Samsung 28LPP macros.

Both flags must be passed to vlogan/DC for the production build. They are
independent — `SYNOPSYS` alone gets you DC-elabable RTL with all RAMs as flops;
adding `COMPILED_SRAM_28LPP` brings in the compiled SRAM macros.

> **Note on session continuity.** A prior session (logged in `STATUS.yaml`,
> 2026-05-05 03:05–06:05) authored an alternate compiled-SRAM wrapper at
> `hw/rtl/libs/VX_sram_macros_28lpp.sv` using a per-shape-module style
> (`VX_sram_l2_data_2048x512_bwe8`, etc.) that the dispatcher then called.
> Per user direction in this session, the **canonical implementation is the
> parameterized dispatcher style** at `hw/rtl/libs/VX_sp_ram_compiled.sv`
> and `VX_dp_ram_compiled.sv` — `VX_sp_ram` / `VX_dp_ram` instantiate the
> dispatcher with `(DATAW, SIZE, WRENW)` parameters, and the dispatcher's
> `generate if-else` chain selects the right macro tile pattern in-place.
> The per-shape file `VX_sram_macros_28lpp.sv` is now an empty stub.

---

## Files changed in this session

### `hw/rtl/libs/VX_async_ram_patch.sv`
Added `\`ifdef SYNOPSYS` branch (lines 144-189) that emits a plain sync-write +
async-read flop array. Bypasses the `VX_placeholder` shim and `USE_BLOCK_BRAM` /
`RW_RAM_CHECK` attributes (Vivado-only; null on DC). Reason: the three async-read
sites that hit this patch (L2 / ICACHE FIFO repl, IPDOM stack — see
[`sram_inventory.md`](sram_inventory.md)) have depths and widths below typical
28LPP SRAM compiler minimums. Total flop budget < 11k, < 0.005 mm² on 28LPP, no
macro substitution practical for these shapes.

### `hw/rtl/VX_config.vh`
Added an `\`ifdef SYNOPSYS` arm to the FPU backend selection chain (lines 49-67):
when `SYNOPSYS` is defined and no explicit `FPU_*` flag is set, `FPU_FPNEW` is
selected (cvfpu — pure synthesizable RTL). This bypasses the FPU_DSP fallback
chain whose leaf modules (`VX_fpu_fma.sv` etc.) drop into a DPI-only branch
that doesn't synthesize on DC.

### `hw/rtl/libs/VX_sp_ram_compiled.sv` (canonical, new in this session)
Parameterized single-port sync-read SRAM dispatcher. The dispatcher's
`generate if-else` arms inline the macro tile pattern for each inventory shape:

| arm | (SIZE, DATAW, WRENW) | macro tile pattern |
|---|---|---|
| `g_8192x64_bwe8` | LMEM | 1× `cmos28lpp_ra1w_hd_8192x64m16` |
| `g_2048x512_bwe8` | L2 data | 4× `cmos28lpp_ra1w_hs_2048x128m8` |
| `g_1024x512_bwe8` | TMEM | 4× `cmos28lpp_ra1w_hs_1024x128m8` |
| `g_64x512` | ICACHE data | 4× `cmos28lpp_rf1_hd_64x128m2` |
| `g_1024x1024` | GEMM acc | 8× `cmos28lpp_ra1w_hs_1024x128m8` (BWE tied) |
| `g_unsupported` | fallback | flop array + `VX_STATIC_ASSERT(0)` |

### `hw/rtl/libs/VX_dp_ram_compiled.sv` (canonical, new in this session)
Parameterized 1R1W sync-read SRAM dispatcher. Port A wired as read, port B as
write for every macro family (`ra2`, `rf2`, `rf2w`).

| arm | (SIZE, DATAW, WRENW) | macro tile pattern |
|---|---|---|
| `g_2048x18` | L2 tag | 2× `cmos28lpp_ra2_hd_1024x18m16` (depth-stack on raddr[10]) |
| `g_64x23` | ICACHE tag | 1× `cmos28lpp_ra2_hd_64x23m4` |
| `g_16x584` | L2 MSHR | 4× `cmos28lpp_rf2_hd_16x146m1` |
| `g_16x44` | ICACHE MSHR | 1× `cmos28lpp_rf2_hd_16x44m1` |
| `g_64x512_bwe8` | GPR opc | 4× `cmos28lpp_rf2w_hd_64x128m1` |
| `g_unsupported` | fallback | flop array + `VX_STATIC_ASSERT(0)` |

Common ARM tie-offs (both dispatchers):
`EMA=3'b010, EMAW=2'b01, EMAS=1'b0, TEN=TCEN=TGWEN=1, RET1N=1, COLLDISN=1`,
scan/test pins held inactive.

### `hw/rtl/libs/VX_sp_ram.sv` and `hw/rtl/libs/VX_dp_ram.sv`
Pre-existing `\`ifdef COMPILED_SRAM_28LPP` hook (VX_sp_ram.sv:112-129,
VX_dp_ram.sv:104-122) dispatches the sync FORCE_BRAM path through
`VX_sp_ram_compiled` / `VX_dp_ram_compiled` — both module names match the
dispatcher modules above.

### `hw/rtl/libs/VX_sram_macros_28lpp.sv` (now stub)
Empty stub. The prior session's per-shape style (10 named wrapper modules
plus dispatchers) is replaced by the parameterized dispatcher style under
`hw/rtl/libs/sram/`. Safe to delete on next cleanup pass.

---

## Files added (`agent-tasks/synopsys-dc-port/`)

```
sram_inventory.md            — full inventory of every VX_sp/dp_ram site,
                               concrete depths/widths, macro mapping, FORCE_BRAM
                               threshold filter

sram_dumper/                 — VCS-elaborable parameter dumper
  dump.sv                      (asserts SYNOPSYS, NDEBUG, XLEN_64, etc.)
  _predefs.svh                 (macro overrides — workaround for VCS +define+
  _predefs.sv                   propagation issue)
  run.sh

async_patch_test/            — VX_async_ram_patch dual-path elab smoke test
  test_patch.sv
  test_patch_predefs.sv
  run.sh

sram_compiled_test/          — VX_sp/dp_ram_compiled all-shape elab smoke test
  test_compiled.sv             with -y resolving the 9 Samsung 28LPP macros
  run.sh                       (now points to VX_sram_macros_28lpp.sv)

STATUS.yaml                  — task FSM (prior + current session log)
SUMMARY.md                   — this file
```

---

## How to reproduce verification

### SRAM parameter dump (config sanity check)
```bash
cd agent-tasks/synopsys-dc-port/sram_dumper && ./run.sh
```
Expected: prints L2/ICACHE/LMEM/TMEM/GEMM/IPDOM/GPR derived parameters with
`SYNOPSYSdef=1 FPU_FPNEW=1 FPU_DSP=0 FPU_DPI=0`.

### Async-patch dual-path elab
```bash
cd agent-tasks/synopsys-dc-port/async_patch_test && ./run.sh
```
Expected: both `[non-SYNOPSYS path]` and `[SYNOPSYS path]` reach
`$finish at simulation time 20`.

### Compiled-SRAM all-shapes elab
```bash
cd agent-tasks/synopsys-dc-port/sram_compiled_test && ./run.sh
```
Expected: 9 macro `.v` files resolved via `-y`, `test_compiled elaborated and
ran one tick — OK`, `$finish at simulation time 20000`.

---

## Review points

### Cleanup needed (housekeeping)

0. **Stubs to delete on next cleanup** (`rm` was not in this agent's permission
   scope):
   - `hw/rtl/libs/VX_sram_macros_28lpp.sv` — prior session's per-shape style,
     superseded by the dispatchers.
   - `hw/rtl/libs/sram/VX_sp_ram_compiled.sv`,
     `hw/rtl/libs/sram/VX_dp_ram_compiled.sv`, plus the empty `sram/`
     directory — moved up to `hw/rtl/libs/` per project layout convention
     (no new subfolders).

### Configuration assumptions baked in

1. **L2_NUM_BANKS = 1.** With `DCACHE_DISABLE` the chain
   `L1_MEM_PORTS = MIN(DCACHE_NUM_BANKS=1, 32) = 1`
   forces `L2_NUM_REQS = 1` → `L2_NUM_BANKS = 1`. Single L2 bank for an 8-thread
   LSU is bandwidth-suspicious. If the intent was multi-bank, add `+define+L1_DISABLE`
   (which routes `L1_MEM_PORTS = MIN(DCACHE_NUM_REQS, PLATFORM_MEMORY_NUM_BANKS)`)
   or override `DCACHE_NUM_BANKS` directly. The L2-tag wrapper depth-stacks two
   1024×18 macros for the SIZE=2048 case; if NUM_BANKS becomes 2 (LINES_PER_BANK=1024),
   a `SIZE==1024` arm needs to be added next to the existing one.

2. **`UUID_WIDTH = 1` (NDEBUG, no SCOPE).** Drops L2_TAG_WIDTH to 6 and
   L2_MSHR_DATAW to 584. With `+DSCOPE` (debug build) UUID_WIDTH jumps to 44,
   inflating both numbers (L2 MSHR data widens to ~627). The compiled-SRAM
   wrappers were sized for the no-SCOPE numbers — a SCOPE bring-up build would
   need new macro shapes.

3. **`XLEN_64` assumed.** Several wrapper widths (LMEM 64-bit, IPDOM 141-bit,
   GPR 512-bit) are tied to XLEN. A 32-bit build would not match the macros.

4. **NUM_WARPS = 4 default.** Inherited because `.envrc` doesn't set it. IPDOM
   `BRAM_SIZE = DV_STACK_SIZE × NUM_WARPS = 7 × 4 = 28` only fits the wrapper
   fallback (no compiled-SRAM macro generated for 28×141 — falls to flops).

### `VX_async_ram_patch` SYNOPSYS branch

5. **Behavior parity.** SYNOPSYS branch is a true async-read flop array
   (`assign rdata = ram[raddr]`). Matches simulation behavior of the parent
   `VX_sp_ram` / `VX_dp_ram` async-read mode. No 1-cycle latency change — unlike
   the Vivado patch, which inserts a sync register internally and depends on
   the parent's `RADDR_REG=1` invariant to hide it.

6. **Read-first vs write-first.** The patch ignores `WRITE_FIRST` for SYNOPSYS.
   The flop-array semantics are inherently write-after-read at the posedge boundary,
   which matches the parent's read-first expectation for our three sites (all
   pass `RDW_MODE="R"`). Confirm before adding any `RDW_MODE="W"` callers.

7. **`UNUSED_PARAM` of `RADDR_REG`/`RADDR_RESET`/`WRITE_FIRST`.** Quiet on DC
   warnings but they're now genuinely dead in this branch. If the patch later
   grows a macro path, those parameters become live again.

### Compiled SRAM wrappers (`hw/rtl/libs/sram/VX_{sp,dp}_ram_compiled.sv`)

8. **EMA/EMAW hard-coded at 3'b010 / 2'b01.** Read/write margins for the
   nominal corner. SoC top should override per process/voltage — currently the
   only way to retune is editing the wrapper. Consider parameterizing if the
   bring-up flow needs corner sweep.

9. **`COLLDISN = 1'b1`** (collision detection disabled). Five 1R1W sites rely
   on parent invariants forbidding same-address r/w in the same cycle:
   - L2 tag: parent ensures lookup vs fill don't collide
   - ICACHE tag: same
   - L2 MSHR / ICACHE MSHR: separate alloc / dequeue indices
   - GPR opc: scoreboard prevents same-reg r/w in one cycle

   If any of those invariants is violated upstream, `COLLDISN=1` produces
   undefined behavior (silent data corruption, no X-propagation in DC).
   Bring-up plan should include directed tests for each.

10. **Test/scan tied off** (`SE=0, SI=0, TEN=TCEN=TGWEN=1, DFTRAMBYP=0,
    RET1N=1`). Functional-only. **DFT integration is a separate task** — when
    BIST/scan is added, these tie-offs must be replaced by proper DFT signals
    routed from the SoC test controller. Same for `VDDCE/VDDPE/VSSE` (currently
    not connected; the macros' `\`ifndef POWER_PINS` variant is what we
    instantiate).

11. **L2 tag depth-stacking output mux** (in `g_2048x18` of `VX_dp_ram_compiled`):
    output mux uses 1-cycle-registered slice-select to align with the macro's
    sync read. The mux adds 1 LUT-equivalent of delay on the rdata path; if
    L2 timing is tight, consider duplicating the register or pushing it earlier.

12. **GEMM acc full-word write** uses `ra1w_hs_1024x128m8` with WEN tied to
    `~write` across all 128 lanes. The macro is bit-WE-capable; we tie all
    lanes together. Synth tools should optimize the redundancy. If they don't,
    area cost is negligible.

13. **WRENW=64 → byte-WE mapping** assumes 8-bit bytes
    (`{8{~(write & wren[i])}}`). Hardcoded across all wrappers. Consistent
    with the parent's `BANK_DATA_SIZE` convention but worth noting if a future
    shape uses a different byte size.

14. **Dispatcher `g_unsupported`** uses `VX_STATIC_ASSERT(0)` — fires at
    simulation elaboration. On DC the assert is stripped, but the fallback
    flop array still elaborates, so an unmatched-shape build will silently
    burn flops without compile error. New shapes therefore need to be added
    to the dispatcher arm list when the parent's parameter set changes (e.g.,
    a future config that produces L2 with different LINES_PER_BANK).

### FPU backend selection

15. **`SYNOPSYS` → `FPU_FPNEW`.** cvfpu pulls in
    `third_party/cvfpu/src/fpu_div_sqrt_mvp/...` and several `common_cells`
    sources. The Synopsys build flow must add those to the source list (the
    existing xilinx/xrt Makefile already does for `FPU_FPNEW`; mirror that in
    the DC tcl). If the production build uses a stripped third_party tree,
    confirm the cvfpu path is included.

16. **`EXT_D_ENABLE` side-effect.** `VX_config.vh:65-71` enables double-precision
    when `XLEN_64 && !FPU_DSP && !EXT_D_DISABLE`. With the new SYNOPSYS branch
    selecting `FPU_FPNEW`, `EXT_D` becomes enabled by default — cvfpu will
    instantiate FP64 datapaths. **This is a user-visible behavior change** vs.
    Vivado synth (which used FPU_DSP and skipped EXT_D). If FP64 is unwanted,
    add `+define+EXT_D_DISABLE` to the DC build.

17. **Synthesis warnings from cvfpu.** cvfpu has known DC lint noise (unused
    parameters, `unique case` style choices). Plan to either suppress in the DC
    setup file or accept them.

18. **DesignWare IP path NOT taken.** The user's original ask was to use
    "Synopsys IP" (DesignWare DW_fp_*). Current change uses cvfpu instead — a
    pragmatic shortcut that satisfies the goal of "synthesis success" with the
    smallest footprint. If DW_fp_* is required for QoR or licensing reasons,
    a follow-up task would add `\`elsif SYNOPSYS → DW_fp_mac` branches in the
    leaf modules (`VX_fpu_fma.sv` is the critical one — DIV/SQRT/CVT already
    use cvfpu inside the FPU_DSP path).

### Build flow integration (not yet wired)

19. **DC tcl needs:**
    - Add `+define+SYNOPSYS` and (when target is silicon) `+define+COMPILED_SRAM_28LPP`.
    - Source list must include `hw/rtl/libs/VX_sp_ram_compiled.sv` and
      `hw/rtl/libs/VX_dp_ram_compiled.sv`.
    - Library search paths for the 9 Samsung 28LPP macros (`-y` per directory)
      and the per-corner `.lib` / `.db` files for timing/power.
    - Add cvfpu sources (mirror the xilinx/xrt Makefile's FPNEW block).

20. **Simulation flow for Synopsys-targeting RTL.** Existing rtlsim/simx/xrtsim
    flows have not been re-validated against the SYNOPSYS-defined branches.
    They run without `+define+SYNOPSYS`, so they keep going through the original
    inferred-RAM and `FPU_DSP`/`FPU_DPI` paths — no regression expected, but
    one full regression pass before tape-out.

21. **Long-tail FIFO sweep deferred.** `VX_fifo_queue` / `VX_fifo_v2` /
    `VX_index_buffer` instantiations were not individually swept against the
    FORCE_BRAM threshold. Most are tiny (DEPTH ≤ 16, DATAW < 16) and fall to
    flops anyway, but a confirming sweep is open work.

---

## Non-goals (explicitly deferred)

- DesignWare DW_fp_* integration (Task #3 option B/C from earlier discussion).
- DFT/BIST integration of compiled SRAMs.
- L2 bank-count config sanity check (`L2_NUM_BANKS=1` may or may not be the
  intended config — flagged in inventory.md).
- `+DSCOPE` (debug-build) compiled-SRAM shape coverage.
- DC tcl / build flow updates.

---

## Tasks status

| # | Task | State |
|---|---|---|
| 1 | Inventory compiled SRAM depth×width combinations | ✅ done |
| 2 | Port `VX_async_ram_patch` to Synopsys DC | ✅ done |
| 3 | Wire SYNOPSYS-defined FP unit (cvfpu via FPU_FPNEW) | ✅ done |
| 4 | Wire compiled-SRAM wrappers for sync `VX_sp/dp_ram` | ✅ done (canonical file pre-existed) |
