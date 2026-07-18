# DMA SRAM RTL Integration Specification

Status: confirmed

## Goal

Map the DMA response RAM shape `(SIZE=8, DATAW=1024, WRENW=1)` to the generated Samsung 28LPP RF2_HD macros instead of the unsupported inferred-RAM fallback.

## Scope

- Modify `hw/rtl/libs/VX_dp_ram_compiled.sv` only.
- Add a dispatcher arm for the exact `8x1024` shape.
- Do not change DMA control logic or other compiled-RAM mappings.

## Design

- Tile the data width in parallel using six `cmos28lpp_rf2_hd_8x160m1` instances for bits `[959:0]` and one `cmos28lpp_rf2_hd_8x64m1` instance for bits `[1023:960]`.
- Drive every macro with the same 3-bit read/write address and read/write enables.
- Keep port A as the read port and port B as the write port.
- Ignore the single whole-word `wren` input, matching the existing native RF2 mappings.
- Use the established RF2 tie-offs, including `EMAA=EMAB=3'b100` and disabled collision detection.
- No read selector register is needed because the macros are width-tiled rather than depth-stacked.

## Verification

- Compile/elaborate an exact `VX_dp_ram_compiled #(1024, 8, 1)` instance with lightweight stubs for the two macro modules.
- Confirm six 160-bit instances and one 64-bit instance elaborate with correct slice widths and 3-bit addresses.
- Run repository formatting/static checks applicable to the changed file.
