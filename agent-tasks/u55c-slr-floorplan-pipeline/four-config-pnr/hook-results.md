# Four-profile floorplan preflight

Checked on 2026-09-07 in a configured XLEN64 build after sourcing the selected
TH32/t4 config. No Vivado synthesis or implementation is invoked by fixtures.

## Changes

- All four configs enable the existing SLR RTL pipeline and physical floorplan.
- Make exports explicit TMEM bank, DMA channel, HBM port and MXU column counts.
  HBM defaults to eight only when absent, matching RTL. Repeated, bare, empty
  and otherwise malformed explicit values are not normalized to valid ones.
- Tcl permits exactly MXU32/4/4/4, MXU32/8/8/8 and legacy MXU16/16/8/8
  (MXU columns/TMEM/DMA/HBM). It checks exact TMEM, DMA and pair-adapter index
  sets, retaining all existing SLR ownership, marked-pair and boundary checks.
- SLR placement remains memory/HBM DMA in SLR0, local DMA/control/ACC in SLR1,
  MXU in SLR2. There are no DMA clock-region pblocks.
- Read-only DCP diagnostic helper CLIs now require explicit DMA/HBM counts.
  They are not used for checkpoint-based implementation retries.
- U55C connectivity previously referenced eight AXI ports unconditionally.
  It now selects four contiguous eight-PC HBM ranges for t4, or the unchanged
  eight four-PC ranges for t8, matching `VX_mem_remap`. Malformed and unsupported
  port counts fail before linking; all 32 physical HBM PCs remain covered.

## Tests

| Source under hw/syn/xilinx/xrt | Result |
|---|---|
| test_slr_floorplan.tcl | PASS: t4/t8/paired inventory, malformed geometry, exact indices, ownership, FF pairs and Laguna mocks |
| tests/test_post_opt_hook.tcl | PASS: 59 lifecycle/hook checks |
| tests/test_post_place_hook.tcl | PASS: 24 checks |
| tests/test_post_place_slr_objects.tcl | PASS: 22 typed-object checks |
| tests/test_post_place_slr_snapshot.tcl | PASS: 13 failure-snapshot checks |
| tests/test_homogeneous_anchors.tcl | PASS: 63 checks, 10,000-leaf fixture |
| tests/test_gen_vitis_ini.py | PASS: 12 tests, including all four sourced configs, strict exports and actual U55C INI connectivity/hook generation |
| tests/test_parse_floorplan_util.py | PASS: 3 parser tests |

Logs are in `build_four_config_pnr_artifacts/`. Expected errors in negative
Tcl fixtures are caught assertions, not failures of the test suite.

Python iteration 1 loaded an obsolete duplicate-definition expectation before
the test edit completed. It expected `4 8` while Make correctly returned
`invalid-duplicate-NUM_HBM_PORTS`. Iteration 2 passed after the fixture was
updated, including empty-plus-valid and bare-definition negative cases.
After adding the U55C connectivity correction, the final 12-test suite passed
in 99.829 seconds; log: `hook-python-connectivity-final.log`.

## Physical launch preparation

The absolute U55C xpfm exists and `platforminfo` opens it. Short-name discovery
fails with a duplicate-platform diagnostic even with PLATFORM_REPO_PATHS set;
the launch helper therefore invokes normal configure/make with the absolute
xpfm rather than relying on run_hw.sh's hardcoded short platform name.
It uses identical source-flow QoR settings: 100 MHz, Explore,
AlternateCLBRouting, ultrathreads off and congestion fail-fast off. All SLR
post-init/post-opt/post-place and route hooks remain enabled.

Fixture success does not establish actual synthesized ownership, Laguna
placement, legal routing or timing closure. Those require the two authorized
TH32 source builds. TH16 implementation is prepared but not launched.
