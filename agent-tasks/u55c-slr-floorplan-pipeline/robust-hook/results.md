# Robust SLR hook implementation and verification

Status: Tcl robustness changes implemented and tested. End-to-end DCP
validation is blocked by an existing synthesized MXU boundary FF issue,
not by the repaired name/ownership matching. No full floorplan PASS is claimed.

## Implementation

- `floorplan.tcl::logical_path` provides a match-only interpretation of
  known synthesized generate boundaries. It accepts `g_slr/u_link` and
  `g_slr.u_link`, and both slash/dot output-completion scopes. Unrelated
  dots, array indices and replicated leaf suffixes are not rewritten.
- Ownership, inventory matching, marked groups, link grouping and hierarchy
  anchor barriers share that interpretation. Actual Vivado object names,
  dictionary keys, PARENT queries and constraint targets remain unchanged.
- Endpoint ownership does not depend on generated FSM/LUT leaf names.
  Missing or malformed transport identity still fails closed.
- Inventory collects all unknown primitives in
  `slr_unclassified_leaves.tsv` and fails before changing pblocks.
- The two observed anonymous receiver LUT1 helpers can recover an owner
  only by proving a direct, exclusive feedback loop on the same unmarked
  state FF in a retained known receiver endpoint. Both actual DCPs show
  this topology on command-receiver read/write pointer FFs in SLR0.
  Original-name proofs go to `slr_recovered_leaves.tsv`. This is not a
  generic topology search, leaf-name exception or default SLR assignment.
- No RTL, cycle latency, resource or architecture changes are included.

## Fast regression

Tests are run from configured build directories after sourcing the matching
TH32/t4 config. Raw logs are ignored build artifacts, not source files.

| Suite | Result | Evidence |
|---|---|---|
| `test_slr_floorplan.tcl` | PASS | `build/pnr/build_four_config_pnr_artifacts/robust-v2-test_slr_floorplan.tcl.log` |
| `test_lifted_owner.tcl` | PASS, 25 checks | `build/pnr/build_four_config_pnr_artifacts/robust-v2-test_lifted_owner.tcl.log` |
| `test_homogeneous_anchors.tcl` | PASS, 89 checks | `build/pnr/build_four_config_pnr_artifacts/robust-v2-test_homogeneous_anchors.tcl.log` |
| `test_post_opt_hook.tcl` | PASS, 59 checks | `build/pnr/build_four_config_pnr_artifacts/robust-v2-test_post_opt_hook.tcl.log` |
| `test_post_place_hook.tcl` | PASS, 24 checks | `build/pnr/build_four_config_pnr_artifacts/robust-v2-test_post_place_hook.tcl.log` |
| `test_post_place_slr_objects.tcl` | PASS, 22 checks | `build/pnr/build_four_config_pnr_artifacts/robust-v2-test_post_place_slr_objects.tcl.log` |
| `test_post_place_slr_snapshot.tcl` | PASS, 13 checks | `build/pnr/build_four_config_pnr_artifacts/robust-v2-test_post_place_slr_snapshot.tcl.log` |
| `test_gen_vitis_ini.py` | PASS, 12 tests (final source) | `build/experiment-archive/build_slr_hook_check/hook-python-v2.log` |

Coverage includes the 4/8/16-array profiles with slash, dot and mixed spelling;
actual failing synthesized cell spelling; renamed/replicated leaves; malformed
endpoints; root-lifted identity rejection; all-unknown diagnostic collection;
preserved original-name keys; mixed-owner hierarchy barriers; direct Q/D pairs
with mixed spelling; and rejection of a TX peer from another stream.

The lifted-owner graph fixture additionally covers input-Q fanout, unsupported
primitives, marked cells, missing nets, extra drivers/sinks, non-FF drivers,
wrong terminals, a different feedback FF/endpoint, top-level ports, misleading
stream names, unknown endpoint identity and node-root mismatch. Negative
results must be an explicit recovery rejection, not a mock runtime error.

The new cross-stream negative fixture initially expected the word `group`,
but the checker correctly reported `unexpected TX peer`. Only the fixture's
expected message was corrected; the rejection was never disabled.

## Real DCP checks

See [dcp-results.md](dcp-results.md) for immutable source checkpoint hashes,
historical failure reproduction, updated-hook attempts, connectivity evidence
and detailed limitations. Both original failures reproduced. The first
updated-hook attempt reported four unknown cells per checkpoint before any
pblock mutation. Iteration 2 classified both checkpoints successfully,
with exactly two connectivity-proven recovered LUT1s per checkpoint.

| Final source-checkpoint check | TH32/t4 | TH32/t8 |
|---|---|---|
| Full ownership and required geometry/hierarchy | PASS | PASS |
| Required marked FF groups | PASS | PASS |
| Exact direct FF pairs | FAIL, 160 errors | FAIL, 160 errors |
| Partition-boundary validation | Not reached | Not reached |
| In-memory pblock application/membership | Not reached | Not reached |

All 160 errors in each checkpoint affect MXU input `block_idx[0..31][0..4]`:
the RX D pin is driven directly by an **unmarked prealign pipe FF Q**, not by
the required marked transport TX FF Q. The checker correctly rejects this;
it is not a missing slash/dot spelling exception.

## Remaining RTL/synthesis work (not implemented)

Relevant source locations in `hw/rtl/core/gemm/VX_gemm_compute_core.sv`:

- Line 1383: `u_prealign_blk_idx_pipe`; its input at line 1388 is
  `prealigner_blk_idx`.
- Line 1539: `g_slr_mxu_input_tx.control_q` is marked `USER_SLL_REG` and
  `SHREG_EXTRACT=NO`, but unlike the data FF immediately below it, is not
  `DONT_TOUCH`-preserved.
- Line 1548: this TX control register samples the same `prealigner_blk_idx`.
- Line 1562: the intended RX control register captures that TX control FF.

The actual DCP connection is consistent with synthesis merging equivalent
TX block-index state into the existing prealign pipe FF. This is an inference
from the RTL and netlist, not a quoted synthesis merge diagnostic.

The recommended next change is narrowly preserving the intended MXU control
TX state (preferably only the affected block-index slice), then freshly
synthesizing from source and repeating these strict checks. That requires
separate RTL/synthesis scope; adding pattern aliases or silently accepting
the unmarked prealign driver would not demonstrate the intended SLR transport.

No synthesis, implementation, DCP save, source-build retry or new RTL
simulation is part of this Tcl-only change. The prior four-config simulation
results remain historical RTL verification, not a new test of these hooks.
