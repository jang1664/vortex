# DMA SRAM Depth Variants Specification

Status: confirmed

## Goal

Prepare compiled SRAM support for future DMA read-slot configurations that
produce `(SIZE=4, DATAW=1024, WRENW=1)` and `(SIZE=16, DATAW=1024, WRENW=1)`.

## Scope

- Generate Samsung 28LPP RF2_HD FE and BE views for the required 4-word and
  16-word width tiles.
- Add exact 4x1024 and 16x1024 dispatcher arms to
  `hw/rtl/libs/VX_dp_ram_compiled.sv`.
- Register all 4/8/16-depth DMA tile macros in the active Synopsys synthesis
  framework's compiled-SRAM list.
- Do not change DMA control logic or the selected read-slot parameter.

## Design

- The RF2_HD mux1 compiler range is 4 to 64 words and 4 to 160 data bits;
  width advances in 2-bit steps.
- Generate `cmos28lpp_rf2_hd_4x160m1`,
  `cmos28lpp_rf2_hd_4x64m1`, `cmos28lpp_rf2_hd_16x160m1`, and
  `cmos28lpp_rf2_hd_16x64m1`.
- For each logical depth, tile 1024 bits as six 160-bit macros covering
  `[959:0]` and one 64-bit macro covering `[1023:960]`.
- Use native address widths of 2 bits for depth 4 and 4 bits for depth 16.
- Keep port A as read, port B as write, ignore the whole-word `wren`, and use
  the established RF2 test and margin tie-offs.
- Keep the existing 8x1024 mapping unchanged.

## Verification

- Validate non-empty FE Verilog/Liberty/DB/LEF and BE GDS/CDL/NDM views for all
  four new macros.
- Check a Synopsys maximum-corner DB for every new macro with `read_db`.
- Compile, elaborate, and functionally simulate exact 4x1024 and 16x1024
  `VX_dp_ram_compiled` instances through `tools/verify_rtl.py` and VCS.
- Run synthesis-framework unit tests and repository formatting/static checks
  for changed files.
