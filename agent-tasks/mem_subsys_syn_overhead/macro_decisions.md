# 28LPP Macro Decisions for Interconnect Overhead Sweep

## Sweep rebase (4/8/16/32 for cache & AXI)

After fixing the EMA timing bug, the sweep is rebased so the smallest point
exercises the **largest** bank capacity (= smallest bank count). The cache
sweep moves from 8/16/32/64 → **4/8/16/32 banks**; AXI does likewise.

The 4-bank cache point (C1) needs one new data macro shape; the tag shape is
covered by depth-stacking the existing `1024x16m16`.

## Shapes & tile patterns

mux factor picks follow what is **already known-good** from
`agent-tasks/synopsys-dc-port/sram_inventory.md` at the same compiler family:

| Shape | RTL site | Macro | Tile |
|---|---|---|---|
| 4096 × 64  BWE8  | `VX_sp_ram` (LMEM 16-bank) | `cmos28lpp_ra1w_hd_4096x64m16` | 1× |
| 2048 × 64  BWE8  | `VX_sp_ram` (LMEM 32-bank) | `cmos28lpp_ra1w_hd_2048x64m16` | 1× |
| 1024 × 64  BWE8  | `VX_sp_ram` (LMEM 64-bank) | `cmos28lpp_ra1w_hd_1024x64m8`  | 1× |
| 4096 × 512 BWE64 | `VX_sp_ram` (DCACHE data 4-bank)  | `cmos28lpp_ra1w_hs_4096x128m8` | 4× width |
| 2048 × 512 BWE64 | `VX_sp_ram` (DCACHE data 8-bank)  | `cmos28lpp_ra1w_hs_2048x128m8` | 4× width |
| 1024 × 512 BWE64 | `VX_sp_ram` (DCACHE data 16-bank) | `cmos28lpp_ra1w_hs_1024x128m8` | 4× width |
|  512 × 512 BWE64 | `VX_sp_ram` (DCACHE data 32-bank) | `cmos28lpp_ra1w_hs_512x128m8`  | 4× width |
| 4096 × 16        | `VX_dp_ram` (DCACHE tag 4-bank)   | `cmos28lpp_ra2_hd_1024x16m16` | 4× depth |
| 2048 × 16        | `VX_dp_ram` (DCACHE tag 8-bank)   | `cmos28lpp_ra2_hd_1024x16m16` | 2× depth |
| 1024 × 16        | `VX_dp_ram` (DCACHE tag 16-bank)  | `cmos28lpp_ra2_hd_1024x16m16` | 1× |
|  512 × 16        | `VX_dp_ram` (DCACHE tag 32-bank)  | `cmos28lpp_ra2_hd_512x16m16`  | 1× |

Unique macros vs. the original 8/16/32/64 sweep: **+1** new
(`ra1w_hs_4096x128m8`). The old 256-deep shapes (`ra1w_hs_256x128m8`,
`ra2_hd_256x16m8`) are no longer referenced but kept in COMPILED_SPECS for
back-compat.

## Mux factor reasoning

- `ra1w_hd` LMEM family — existing 8192x64m16 confirms (m16, depth ≥ 16). Same m16 used for 4096/2048/1024 (rows = 256/128/64).
- `ra1w_hs` cache-data family — existing 2048x128m8, 1024x128m8 confirms m8. Same m8 used for 512/256 (rows = 64/32, both safely above ra1_hs minimum).
- `ra2_hd` tag family — existing 1024x18m16 confirms (depth-stack template). For 256-deep, drop to m8 (32 rows) to stay above ra2_hd minimum-row floor (ra2_hd 64x23m4 already proven at m4, so m8 at depth 256 is safe). 512-deep stays m16 (32 rows).

## ARM tie-off conventions

- 1P ra1w_*: `EMA=3'b100, EMAW=2'b00, EMAS=1'b0 (hs only), TEN=TCEN=TGWEN=1, TWEN/TA/TD=0, SI=SE=0, RET1N=1, DFTRAMBYP=0`
- 2P ra2_*: above + `COLLDISN=1`

**EMA/EMAW = 100/00 (not 010/01).** At the SS 0p900v 125c MAX corner, ARM's
.lib only provides characterized CLK→Q delays for `EMA >= 3'b100`; lower
values (010, 001, 000) emit 999.0 placeholder timing. The earlier sweep
used 010/01 and the resulting `999.0 ns` data-arrival paths invalidated the
optimizer's decisions. Matches `hw/rtl/verification/sram_bank.sv` (FICIM).

## Tile semantics

**LMEM 4096/2048/1024 × 64 BWE8** — single tile, byte-WE replicated as `{8{~(write & wren[i])}}` per byte.

**DCACHE data 512/256 × 512 BWE64** — width tile of 4. Each tile carries 16 byte-WEs `wen_n[i*8 +: 8] = {8{~(write & wren[t*16 + i])}}`.

**DCACHE tag 2048 × 16** — depth-stack of 2 with raddr[10]/waddr[10] selecting low/high half. Q is 1-cycle delayed → `ra_top_r` registered to mux on read.

**DCACHE tag 1024/512/256 × 16** — single tile, width adjusted to 16 (no padding needed since 16 is a valid bit count for ra2_hd compiler).

## Risks / fallbacks

If the compiler refuses a depth/mux combo (typical reason: row count below per-instance minimum), retry with the next-lower mux factor: m16 → m8 → m4. The RTL arm structure does not change — only the underlying macro module name and the input list to memory_compiler.
