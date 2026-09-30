# C4 reset alias boundary-check diagnosis

The MXU-only boundary checker differs from feat/gemv's
`slr_floorplan_report.tcl::validate_boundary_nets`. The previous alignment
ported placement groups and object/pblock helpers, not this boundary algorithm.

## Evidence

- The failed C4 runtime Tcl is byte-identical to current mxu_slr_floorplan.tcl.
- Placer log line 3246 reports BUFG insertion on the core reset net
  `__core_reset/g_relay.reset_r_repN_12`, driving 2,078 loads.
- Line 3454 rejects the MXU hierarchy alias `g_relay.reset_r_repN_12_alias`
  because it reaches the memory arbiter's `valid_out_r_reg` outside MXU ownership.
- Opening the actual C4 kernel synthesis DCP identifies that exact destination
  as FDRE. Its R pin is driven by the core reset relay FF Q. Its D pin has a
  separate LUT5 driver. See pin-summary.json and inspect-synth-reset.log.
- A plain Tcl comparison invokes both actual checker functions with the same
  connection model: reset alias -> R is rejected only by the current checker;
  reset-named signal -> D is rejected by both when owners differ; an external
  unowned reset destination is rejected only by the current checker.

## Algorithm differences

Current check_tree_ports skips only the exact hierarchy pin names clk_i and
resetn_i plus literal constant nets. It then requires every connected cell to
belong to SLR2, without looking at destination pin roles.

The feat/gemv checker gathers boundary nets, identifies driver/destination
pins, skips unowned endpoints, and exempts dedicated clock/reset terminals
(R, CLR, PRE, CLK, etc.) for owned cross-SLR edges. A reset-like name alone
does not exempt a data/ready connection. It writes per-net/pin TSV evidence.

## Conclusion and limits

The evidence identifies a reset-alias false positive in the adapted checker,
not a demonstrated payload crossing violation. The specific post-place
netlist cannot be directly reopened: C4 has no saved placed checkpoint.
The pin-level audit above is of the actual synthesis DCP, corroborated by
placement logs and direct checker reproduction; a full post-place recheck
remains necessary after correction.

An aligned fix should adapt feat/gemv's net/pin boundary validation to MXU
scope, retain its dedicated-control-pin exceptions, and document explicitly
whether unowned data endpoints are audited (the current MXU contract is
stricter than the original full-node checker). Do not simply exempt all
reset-named nets. Save a placed DCP before running rejection gates.

No production RTL/Tcl changes or PnR launches were made during this diagnosis.
