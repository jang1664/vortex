# ACC Compiled SRAM Specification

## Goal

Map the GEMM accumulator memory used by the target depth-512 configurations to
Samsung 28LPP compiled SRAM macros instead of the unsupported synchronous
register-array fallback. This removes the unintended standard-cell ACC storage
implementation and makes ACC storage consistent with the existing TMEM
width-tiling approach.

## Scope

- Add a compiled-SRAM mapping for the ACC shape used by:
  - `configs/naive_gemm_th32_tcol32_hwexp_dcache.sh`
  - `configs/improve_th32_tcol32_hwexp_dcache.sh`
- Primary RTL target: `hw/rtl/libs/VX_sp_ram_compiled.sv`.
- Update Synopsys compiled-SRAM inventory or binding code only if required for
  the `cmos28lpp_ra1w_hs_512x128m8` macro to be analyzed and linked.
- Reuse the existing ACC interface and memory semantics. Do not change GEMM
  addressing, capacity, banking, or pipeline behavior.

## Design Decisions

- The target logical ACC organization remains four `512x1024` banks, totaling
  256 KiB for `MXU_COL=32`.
- Implement each logical bank as eight `512x128` HS macros tiled across data
  width, matching the style already used for TMEM-compatible wide memories.
- The complete ACC therefore uses 32 compiled SRAM macros.
- Preserve `WRENW=1` full-word write behavior by driving each macro's write
  enable across all 128 bits.
- Preserve the existing single synchronous read interface and output register
  behavior expected by `VX_sp_ram`.
- Do not switch to oversized depth-1024 HD macros in this change. That option
  remains a separate area/timing experiment.

## Constraints and Assumptions

- Samsung 28LPP `cmos28lpp_ra1w_hs_512x128m8` Liberty, LEF, and Verilog views
  are available in the local compiled-memory inventory.
- The synthesis flow must retain the macro instances as black boxes rather than
  synthesize their behavioral models.
- Existing unrelated worktree changes must be preserved.
- Verification should cover elaboration/compilation of the new parameter arm
  and functional GEMM ACC reads/writes.

## Final Agreed Specification

**Confirmed 2026-07-30:** Map `SIZE=512`, `DATAW=1024`, `WRENW=1` in
`VX_sp_ram_compiled` to eight `cmos28lpp_ra1w_hs_512x128m8` macros per logical
ACC bank, following the existing TMEM-style width tiling.
