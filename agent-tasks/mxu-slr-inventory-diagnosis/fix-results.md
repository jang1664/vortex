# MXU SLR floorplan fix and existing-DCP validation

The MXU-only floorplan now keeps placement ownership separate from marked
crossing FF endpoints, matching the feat/gemv approach. Local unmarked LUTs
remain in the appropriate SLR pblock. Missing FF attributes, attributes on
non-FFs, missing endpoint groups and logic between TX Q and RX D still fail.

Real DCP checks also exposed two Vivado integration issues:
- Relationship queries now resolve actual cell objects rather than reusing
  handles stored in Tcl maps, including indexed naive control registers.
- Vivado 2025.1 resets IS_SOFT when other pblock flags are set. The script
  sets IS_SOFT last and verifies all three flags are false after assignment.
  A minimal synthesized probe reproduced the setter side effect and verified
  the corrected order. The flags are reasserted before and after attaching cells.

Bulk property queries and local lookup arrays follow the source branch's
approach to avoid prohibitively slow per-cell queries on full kernel designs.
MXU port checks retain literal-constant and unconnected-port handling.

## Results

| Existing synthesis DCP | Owned primitives | Marked FFs | Direct TX/RX pairs | Result |
|---|---:|---:|---:|---|
| C2: TCU + naive | 146794 | 4684 | 2342 | PASS |
| C3: naive | 146794 | 4684 | 2342 | PASS |
| C4: improve | 148004 | 4684 | 2342 | PASS |

Each DCP passed post-init pblock assignment, per-cell membership, direct
FF links and MXU-port ownership, followed by inventory refresh on the same
netlist. No input DCP was rewritten. This is synthesis-netlist validation;
no actual opt_design, place_design or route_design was run in these checks.
Physical SLR placement, Laguna mapping and routed timing remain for PnR.

The final plain-Tcl suite passed 36 checks, including local helper LUTs,
missing/invalid marked endpoints, an in-path LUT, unassigned helper cells,
Vivado's pblock-property side effect and unconnected ports. Seven existing
Vitis configuration generator tests also passed.

Evidence: verification.json, final-unit.log,
object-dcp-th32_c1_tcu_naive_m32_tcol32.log,
object-dcp-th32_c1_naive_m32_tcol32.log, and
verified-dcp-improve/validation-final.log. Per-pair TSV reports are inside
the corresponding report directories. Earlier failed and interrupted attempts
are retained separately and are not counted as successful checks.

## Reproduction

From a configured build directory, source the relevant config and run:

```sh
vivado -mode batch -nolog -nojournal \
  -source ../hw/syn/xilinx/xrt/tests/check_mxu_slr_dcp.tcl \
  -tclargs /absolute/path/to/kernel.dcp /absolute/path/to/new-report-directory
```

The report directory must be new. The script opens the checkpoint in memory
and does not overwrite it.

## PnR operations

The user requested C2 and C3 be stopped; their original process trees were
terminated while C1 remained running. After all three DCP checks passed,
C2/C3/C4 were restarted with a fresh postfix and independent outputs.
See ../pnr-c2-c3-c4-slrfix-20260930/status.json and manifest.json.
The monitor records hourly status, checks for failures each minute and invokes
notify-me alarm on problems. C1 retains its original monitor and output.
