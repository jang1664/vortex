# MXU post-place SLR query diagnosis

The per-cell SLR check in `hw/syn/xilinx/xrt/mxu_slr_floorplan.tcl:260`
compares the result of `get_slrs -of_objects $cell` directly with the owner.
Vivado 2025.1 returns an empty SLR collection for the DSP48E2 macro in the
minimal reproduction, even after successful placement in SLR2.

## Reproduction

All synthesis/placement probes ran from the configured `build` directory with
`configs/th32_c1_improve_m32_tcol32.sh` sourced.

- `probe.log`: ordinary FDRE queried directly returns SLR2.
- `indexed-probe.log`: indexed FDRE names also return SLR2.
- `dsp-placed-probe.log`: DSP48E2 (IS_PRIMITIVE=1, PRIMITIVE_LEVEL=MACRO),
  LOC=DSP48E2_X0Y280. After successful `place_design`, direct cell-to-SLR query
  returns empty; cell-to-site-to-SLR query returns SLR2.
- `dsp-probe-placed.dcp`: retained minimal placed checkpoint.

## Why earlier validation did not catch this

The existing kernel DCP validation only ran unplaced post_init/post_opt checks.
The plain Tcl fixture's get_slrs stub returns the expected ownership for DSPs,
so it does not model this Vivado macro behavior.
The feat/gemv post-place routine queries a group of cells together, whereas the
MXU-only adaptation checks each primitive separately. A collection query can
still return the expected SLR from other cells when a macro contributes none.

## Implemented alignment with feat/gemv

The user requested the original grouped-query algorithm rather than a new
per-cell site-based algorithm. The implementation now ports `cell_objects`,
`cell_properties`, `check_pblock_properties`, and the group membership check
from feat/gemv's floorplan.tcl. The post-place gate queries a resolved ownership
collection once per SLR, matching feat/gemv's slr_floorplan_report.tcl.

Scope adaptations: groups {1 2}, pblock_mxu_slr prefix, current
u_VX_gemm_unit/u_mxu paths, the six MXU crossing banks and local alignment bank.
DMA and TMEM paths remain excluded. MXU boundary/direct-FF checks retain the
current RTL interface and exclusive-fanout contract. The previously measured
Vivado 2025.1 pblock setter order (IS_SOFT last) is retained.

Additional test evidence:
- Existing checker fails on a physically placed SLR2 DSP: reproduce-checker.log.
- C4 opt checkpoint confirms the failing product[0][0] is a DSP48E2 MACRO
  assigned to pblock_mxu_slr2: inspect-opt.log.
- Plain Tcl ownership/link tests: 36 pass; macro empty-query behavior included.
- Adapted feat/gemv typed-object regressions: 22 pass.
- Vitis ini generator: 7 tests pass.
- Real placement and C2/C3/C4 DCP checks: see verification.json when complete.

## Limits and recovery

The failed C4 run has an opt DCP but no placed DCP: the post-place hook failed
before the generated implementation script's write_checkpoint. Its complete
physical placement cannot be audited from the remaining checkpoint. After a
checker fix, C4 can rerun placement from the opt DCP without resynthesis, with
checkpoint capture before validation to preserve evidence if another gate fails.
The initial diagnosis left source and jobs unchanged. Subsequent user authorization
requested alignment with feat/gemv, verification, and PnR restart.
