# LPP28 HS SRAM Mapping Specification

Status: confirmed

## Goal

Generate legal Samsung 28LPP high-speed SRAM macros for 64-bit banks and make
the compiled single-port SRAM dispatcher select HS or HD macros through an RTL
parameter. HS is the default so every existing `VX_sp_ram` instance uses HS in
the 28LPP compiled-SRAM flow without call-site edits.

## Scope

- Generate RA1-HS `512/1024/2048/4096x64m8`, `8192x64m16`, and RF1-HS
  `64x128m2` artifacts with the hwexplorer memory compiler.
- Add `SRAM_TYPE = "HS"` to `VX_sp_ram` and `VX_sp_ram_compiled`.
- Support `"HS"` and `"HD"` mappings for every currently registered
  `VX_sp_ram_compiled` shape.
- Keep `VX_dp_ram` and its RA2/RF2 mappings unchanged.
- Register the generated macros in Synopsys SRAM inventories.
- Verify both selectors and recompute 1 MiB and 2 MiB LMEM-only versus
  LMEM/ACC/TMEM raw macro area from generated LEFs.

## Design Decisions

- HS is the default and invalid selector strings fail a static assertion.
- Existing HS x128 tiling remains in use for wide RA1 arrays; new x64 HS
  macros are used for 64-bit banks.
- The installed RA1-HS compiler supports at most 144 data bits for m4/m8, so
  native x512 and x1024 macros are illegal. TMEM therefore uses four x128
  tiles and ACC uses eight x128 tiles per logical bank.
- The ICACHE `64x512` mapping selects four RF1-HS `64x128m2` macros for HS
  and the existing RF1-HD equivalent for HD.
- HD wide arrays use x64 width tiling. Logical depths 256 and 512 use the
  lower address range of a depth-1024 HD macro because exact HD macros do not
  exist.
- Unsupported shape/type combinations fail rather than silently synthesizing
  a register array.
- Generated PDK artifacts remain under `/home/data/memory_compiler/28LPP` and
  are not committed to Vortex.

## Constraints

- Preserve existing user changes, especially
  `hw/syn/synopsys/top_analysis/run_top.sh`.
- Source the applicable Vortex configuration before RTL or synthesis runs.
- Activate the Conda `stable` environment for memory generation and Synopsys
  execution. It provides Python 3.9 and PyYAML.
- Stage the read-only hwexplorer memory compiler under gitignored `build/`
  because it writes a dynamic environment file beside its sources.
- Use actual LEF dimensions; do not estimate x64 area by halving x128 area.

## Acceptance Criteria

- All requested FE/BE macro artifacts exist and include LEF, Verilog, Liberty
  DB, GDS, and NDM views.
- HS and HD wrapper elaboration/function tests pass for registered shapes.
- Default-HS top synthesis links the new macros without unresolved references
  or `g_unsupported_ram_reg` under LMEM, ACC, or TMEM.
- Documentation reports exact 1 MiB and 2 MiB raw macro overhead from LEFs.
