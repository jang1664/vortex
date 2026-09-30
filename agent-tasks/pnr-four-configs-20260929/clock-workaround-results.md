# Clock API workaround port

The four PnR jobs and their monitor were stopped at the user request.
Their output directories and logs are preserved. No matching processes
remained after shutdown. PnR has not been restarted.

Ported feat/gemv commit `866681b2d420b221b2e51319e513bbb399ae8e4d`
without conflicts. The hardware INIT_DESIGN.PRE hook rewrites four ocl_util
clock API callers in memory for Vivado 2025.1 and U55C. Existing MXU SLR
and congestion hooks remain registered.

Validation:
- Seven configuration-generator tests passed, including hardware-only
  registration, SLR coexistence and copying the hook into xrt_backup.
- Tcl regression passed deferred project lookup, all four API keys,
  repeated sourcing, other part/version preservation and fail-fast behavior
  without partial patching when vendor procedures change.
- Installed Vitis/Vivado 2025.1 procedures returned exact 100, 125 and
  300 MHz solutions with an in-memory U55C project. See
  `validate_vendor_clock.tcl` and `vendor-clock-frequencies.log`.
- The initial vendor smoke check only validated that calls returned without
  errors; its requested-frequency property was empty. The final check uses
  the actual ChosenM, ChosenD and ChosenDiv0 values to verify each frequency.

These checks do not constitute a completed PnR run or timing closure.
A restart should use a fresh postfix so the aborted runs remain intact.
