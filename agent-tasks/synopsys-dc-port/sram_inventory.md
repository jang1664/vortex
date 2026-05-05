# vortex_afu Compiled SRAM Inventory (Samsung 28LPP)

Branch: `fpint_improve`
Target: Synopsys Design Compiler synthesis of `vortex_afu` (Vivado/Xilinx flow continues to use BRAM/URAM inference).

This inventory enumerates every `VX_sp_ram` / `VX_dp_ram` site in the active build, resolves its `(depth × width)` to concrete numbers using the `.envrc` configuration, and groups them into the unique compiled-SRAM shapes that need to be procured from the Samsung 28LPP memory compiler.

## Build configuration

From `.envrc` (verbatim) plus the synthesis flow defaults that come from `hw/syn/xilinx/dut/common.mk` (`-DSYNTHESIS -DNDEBUG`) and `config.mk` (`XLEN ?= 64` → `-DXLEN_64`):

```
SYNTHESIS, NDEBUG, XLEN_64
NUM_CLUSTERS=1, NUM_CORES=1, NUM_THREADS=8, NUM_WARPS=4 (default)
DCACHE_DISABLE, L2_ENABLE
LMEM_LOG_SIZE=19      (LMEM = 512 KB)
TMEM_BANK_SIZE=65536  (64 KB per TMEM bank)
NUM_DMA_CHANNELS=8    (8 TMEM banks)
GEMM_ACC_MEM_DEPTH=1024
MXU_COL_TILE=1
MEM_ADDR_WIDTH=34, PLATFORM_MEMORY_NUM_BANKS=32, PLATFORM_MERGED_MEMORY_INTERFACE
EXT_TCU_ENABLE, TCU_BHF
```

Resolved derived parameters (verified by VCS-elaborated dumper of `VX_gpu_pkg`):

| Parameter | Value | Source |
|---|---|---|
| XLEN | 64 | `-DXLEN_64` |
| UUID_WIDTH | 1 | `NDEBUG`, no `SCOPE` (`VX_gpu_pkg.sv:65-73`) |
| PC_BITS | 62 | `XLEN-2` with `NDEBUG` |
| NUM_REGS | 64 | `REG_TYPES=2` (EXT_F enabled by default) |
| NUM_OPCS / PER_ISSUE_WARPS | 1 / 4 | derived from NUM_WARPS=4, ISSUE_WIDTH=1 |
| SIMD_WIDTH / NUM_LSU_LANES | 8 / 8 | `= NUM_THREADS` |
| LMEM_NUM_BANKS | 8 | `= NUM_LSU_LANES` |
| L2_NUM_REQS / L2_NUM_BANKS | **1 / 1** | `MIN(L2_NUM_REQS, 16)` chain — see notes |
| L2_LINES_PER_BANK | 2048 | `(1 MB / 1 bank) / (64 B × 8 ways)` |
| L2_TAG_WIDTH (interface) | 6 | depends on UUID_WIDTH=1 |
| ICACHE_LINES_PER_BANK | 64 | `(16 KB / 1 bank) / (64 B × 4 ways)` |
| ICACHE_TAG_WIDTH (interface) | 3 | `UUID_WIDTH + NW_WIDTH` = 1+2 |

> **Note on `L2_NUM_BANKS=1`.** The chain `DCACHE_DISABLE → DCACHE_NUM_BANKS=1 → L1_MEM_PORTS=1 → L2_NUM_REQS=1 → L2_NUM_BANKS=1` collapses the L2 to a single bank, single input port. With 8-thread LSU traffic this looks bandwidth-starved. If the intent was multi-bank L2, add `+define+L1_DISABLE` (which makes `L1_MEM_PORTS = MIN(DCACHE_NUM_REQS, PLATFORM_MEMORY_NUM_BANKS)`) or override `DCACHE_NUM_BANKS` directly.

## RAM-site inventory (resolved)

All sites below sit above the FORCE_BRAM threshold and therefore need a compiled SRAM macro on Samsung 28LPP. Anything below the threshold maps to flops and is excluded.

FORCE_BRAM threshold (from `VX_platform.vh`):
```
((d ≥ 64) ∨ (w ≥ 16) ∨ (d×w ≥ 512))  ∧  (d×w ≥ 64)
```

| # | Owner | RTL site | depth | width | port | BWE | sync read | RDW | count |
|---|---|---|------:|------:|------|----:|:---------:|:---:|------:|
| 1 | L2 data store | `VX_cache_data.sv:124` (`g_data_store`) | 2048 | 512 | 1P-RW | 8 b (WRENW=64) | sync | R | 8 |
| 2 | L2 tag store | `VX_cache_tags.sv:99` (`g_tag_store`) | 2048 | 18 | 1R1W | – | sync | R | 8 |
| 3 | L2 FIFO replacement | `VX_cache_repl.sv:164` (`g_fifo`) | 2048 | 3 | 1P-RW | – | **async** ⚠ | R | 1 |
| 4 | L2 MSHR data | `VX_cache_mshr.sv:219` (`mshr_store`) | 16 | 584 | 1R1W | – | sync (RADDR_REG=1) | R | 1 |
| 5 | ICACHE data store | `VX_cache_data.sv:124` | 64 | 512 | 1P-RW | – (WRENW=1, WRITE_ENABLE=0) | sync | R | 4 |
| 6 | ICACHE tag store | `VX_cache_tags.sv:99` | 64 | 23 | 1R1W | – | sync | R | 4 |
| 7 | ICACHE FIFO replacement | `VX_cache_repl.sv:164` | 64 | 2 | 1P-RW | – | **async** ⚠ | R | 1 |
| 8 | ICACHE MSHR data | `VX_cache_mshr.sv:219` | 16 | 44 | 1R1W | – | sync (RADDR_REG=1) | R | 1 |
| 9 | LMEM bank | `VX_local_mem.sv:161` (`lmem_store`) | 8192 | 64 | 1P-RW | 8 b (WRENW=8) | sync | R | 8 |
| 10 | TMEM bank | `VX_tensor_mem_bank.sv:108` (`sp_ram`) | 1024 | 512 | 1P-RW | 8 b (WRENW=64) | sync | R | 8 |
| 11 | GEMM accumulator | `VX_gemm_unit.sv:1173` (`VX_sp_ram_instance`) | 1024 | 1024 | 1P-RW | – (WRENW=1) | sync | R | 4 |
| 12 | GPR/FPR opc bank | `VX_opc_unit.sv:279` (`gpr_ram`) | 64 | 512 | 1R1W | 8 b (WRENW=64) | sync | R | 4 |
| 13 | IPDOM stack | `VX_ipdom_stack.sv:101` (`ipdom_store`) | 28 | 141 | 1R1W | – | **async** ⚠ | R | 1 |

Excluded (below threshold or forced non-SRAM):
- `VX_fetch.sv:53` (`tag_store`): 4×70 with `LUTRAM=1` → distributed RAM/flops by parameter, never compiled SRAM.
- `VX_scope_tap.sv:112,134`: `DBG_TRACE_*` / `SCOPE`-only — guarded out by synthesis flags.
- `hw/rtl/patch/*`: sandbox copies, not in the build path (verified against `gen_sources.sh`).
- All other `VX_fifo_queue` / `VX_fifo_v2` / `VX_index_buffer` sites with default DEPTH (≤16) and small DATAW (<16) — they fall below threshold and infer to flops.

## Unique compiled-SRAM shapes (deduplicated)

What we actually need to ask the SRAM compiler for:

### Sync-read (1P-RW with byte-write enable)

| depth | width | BWE granularity | count | owners |
|------:|------:|----------------:|------:|--------|
| 2048 | 512 | 8 b (×64 lanes) | 8 | L2 data |
| 8192 | 64 | 8 b (×8 lanes) | 8 | LMEM |
| 1024 | 512 | 8 b (×64 lanes) | 8 | TMEM |

### Sync-read (1P-RW, no byte-write)

| depth | width | count | owners |
|------:|------:|------:|--------|
| 64 | 512 | 4 | ICACHE data (WRITE_ENABLE=0) |
| 1024 | 1024 | 4 | GEMM accumulator |

### Sync-read (1R1W dual-port, no byte-write)

| depth | width | count | owners |
|------:|------:|------:|--------|
| 2048 | 18 | 8 | L2 tag |
| 64 | 23 | 4 | ICACHE tag |
| 16 | 584 | 1 | L2 MSHR (RADDR_REG=1) |
| 16 | 44 | 1 | ICACHE MSHR (RADDR_REG=1) |

### Sync-read (1R1W dual-port, with byte-write)

| depth | width | BWE granularity | count | owners |
|------:|------:|----------------:|------:|--------|
| 64 | 512 | 8 b (×64 lanes) | 4 | GPR/FPR opc |

### Async-read ⚠ (rely on `VX_async_ram_patch`)

These three sites use `OUT_REG=0 + RADDR_REG=1`. On Vivado the patch couples a sync BRAM to a `VX_placeholder` LUT shim to fake a 0-cycle read; **on Synopsys DC there is no such shim, so the patch must be ported (Task #2 of the Synopsys port plan) or these will fall back to flops.**

| depth | width | port | count | owners |
|------:|------:|------|------:|--------|
| 2048 | 3 | 1P-RW | 1 | L2 FIFO replacement |
| 64 | 2 | 1P-RW | 1 | ICACHE FIFO replacement |
| 28 | 141 | 1R1W | 1 | IPDOM stack |

## Per-shape totals

Total instance count: **53** (8+8+1+1 + 4+4+1+1 + 8+8+4+4+1).

Total bit storage:
- L2 data:          8 × 2048 × 512  = 8.0 Mb
- L2 tag:           8 × 2048 × 18   = 288 kb
- L2 FIFO repl:     1 × 2048 × 3    = 6 kb
- L2 MSHR:          1 × 16   × 584  = 9.1 kb
- ICACHE data:      4 × 64   × 512  = 128 kb
- ICACHE tag:       4 × 64   × 23   = 5.6 kb
- ICACHE FIFO repl: 1 × 64   × 2    = 128 b
- ICACHE MSHR:      1 × 16   × 44   = 0.7 kb
- LMEM:             8 × 8192 × 64   = 4.0 Mb
- TMEM:             8 × 1024 × 512  = 4.0 Mb
- GEMM acc:         4 × 1024 × 1024 = 4.0 Mb
- GPR opc:          4 × 64   × 512  = 128 kb
- IPDOM:            1 × 28   × 141  = 3.9 kb
- **Total:** ≈ **20.5 Mb on-chip SRAM**

The four big consumers (L2 data, LMEM, TMEM, GEMM acc) account for ~20 Mb of the 20.5 Mb total.

## How the numbers were verified

A small VCS dumper was elaborated against the active configuration to print derived `localparam` values from `VX_gpu_pkg`. Source files used:

- Pre-define wrapper that sets `SYNTHESIS, NDEBUG, XLEN_64` and the `.envrc` macros before any package compile.
- `VX_gpu_pkg.sv`, `fpu/VX_fpu_pkg.sv`, `verification/cf_math_util_pkg.sv`, `verification/VX_utils_pkg.sv`, `tcu/VX_tcu_pkg.sv`.
- A custom `dump.sv` that imports `VX_gpu_pkg` and `$display`s the relevant numbers.

Concrete dump output (key lines):

```
== flags ==
XLEN=64  XLEN_64def=1  XLEN_32def=0  NDEBUGdef=1
== L2 ==
L2_NUM_BANKS=1  L2_NUM_REQS=1  L1_MEM_PORTS=1
L2_LINES_PER_BANK=2048  L2_LINE_W=512  L2_TAG_W(cache)=17  L2_TAG_WIDTH(intf)=6
L2_WORD_SEL_W=1  L2_REQ_SEL_W=1  L2_MSHR_DATAW=584  WRENW(L2 data)=64
REPL_POLICY=1 (0=rand,1=fifo,2=plru)  WAYS=8  WAY_SEL_W=3
== ICACHE ==
IC_LINES_PER_BANK=64  IC_LINE_W=512  IC_TAG_W(cache)=22  ICACHE_TAG_WIDTH(intf)=3
IC_WORD_SEL_W=4  IC_REQ_SEL_W=1  IC_MSHR_DATAW=44
ICACHE_REPL_POLICY=1  WAYS=4  WAY_SEL_W=2
== LMEM ==
LMEM_NUM_BANKS=8  WORDS_PER_BANK=8192  WORD_W=64 (WRENW=8)
== TMEM ==
TMEM_NUM_BANKS=8  NUM_WORDS=1024  DATA_W=512 (WRENW=64)
== GEMM ACC ==
ACC_BANKS=4  DEPTH=1024  DATAW=1024
== IPDOM ==
IPDOM_DEPTH=7  IPDOM_WIDTH=70  BRAM_SIZE=28  BRAM_DATAW=141
== GPR ==
GPR_BANKS=4  BANK_SIZE=64  BANK_DATAW=512  WRENW=64
== misc ==
UUID_WIDTH=1  NW_WIDTH=2  PC_BITS=62  NUM_REGS=64  SIMD_WIDTH=8  SIMD_COUNT=1
PER_ISSUE_WARPS=4  NUM_OPCS=1
```

The dumper sources are checked in under `agent-tasks/synopsys-dc-port/sram_dumper/` for reproducibility.

## Open follow-ups

1. **L2 bank count sanity check** — confirm with the architect whether `L2_NUM_BANKS=1` is intentional or whether `L1_DISABLE` should be added.
2. **`SCOPE`-enabled debug build** — `+DSCOPE` raises `UUID_WIDTH` from 1 to 44, which inflates every cache `TAG_WIDTH`/`MSHR_DATAW`. If the silicon also targets a scope-enabled bring-up build, list the scope build's shapes separately.
3. **Long-tail FIFO sweep** — `VX_fifo_queue` / `VX_fifo_v2` / `VX_index_buffer` instantiations have not all been individually checked. Most are tiny (DEPTH ≤ 16, DATAW < 16) and fall below the FORCE_BRAM threshold, but a confirming sweep with the dumper extended to walk every instance would close out the inventory.
4. **Async-read patch on Synopsys** — items #3, #7, #13 require the Synopsys port of `VX_async_ram_patch` (Task #2 of this porting effort). **Done** (`hw/rtl/libs/VX_async_ram_patch.sv`, smoke test under `agent-tasks/synopsys-dc-port/async_patch_test/`).
5. **Sync-RAM compiled-SRAM integration** — **Done** (items #1, #2, #4, #5, #6, #8, #9, #10, #11, #12). `hw/rtl/libs/sram/VX_sp_ram_compiled.sv` and `VX_dp_ram_compiled.sv` provide the dispatcher; the existing `\`ifdef COMPILED_SRAM_28LPP` hook in `VX_sp_ram.sv:112-129` / `VX_dp_ram.sv:104-122` routes the sync `FORCE_BRAM` path through it. Macro mapping:

| inventory shape | macro tile pattern |
|---|---|
| LMEM 8192×64 BWE/8b | 1× `cmos28lpp_ra1w_hd_8192x64m16` |
| L2 data 2048×512 BWE/8b | 4× `cmos28lpp_ra1w_hs_2048x128m8` (width tile) |
| TMEM 1024×512 BWE/8b | 4× `cmos28lpp_ra1w_hs_1024x128m8` (width tile) |
| ICACHE data 64×512 | 4× `cmos28lpp_rf1_hd_64x128m2` (width tile) |
| GEMM acc 1024×1024 | 8× `cmos28lpp_ra1w_hs_1024x128m8` (width tile, BWE tied to write) |
| L2 tag 2048×18 (1R1W) | 2× `cmos28lpp_ra2_hd_1024x18m16` (depth-stack on raddr[10]/waddr[10]) |
| ICACHE tag 64×23 (1R1W) | 1× `cmos28lpp_ra2_hd_64x23m4` |
| L2 MSHR 16×584 (1R1W) | 4× `cmos28lpp_rf2_hd_16x146m1` (width tile) |
| ICACHE MSHR 16×44 (1R1W) | 1× `cmos28lpp_rf2_hd_16x44m1` |
| GPR opc 64×512 BWE/8b (1R1W) | 4× `cmos28lpp_rf2w_hd_64x128m1` (width tile) |

ARM tie-offs (per macro): EMA=3'b010, EMAW=2'b01, EMAS=1'b0 (hs only), TEN=TCEN=TGWEN=1, TWEN/TA/TD=0, SI=SE=0, RET1N=1, DFTRAMBYP=0, COLLDISN=1. Smoke test in `sram_compiled_test/`.
