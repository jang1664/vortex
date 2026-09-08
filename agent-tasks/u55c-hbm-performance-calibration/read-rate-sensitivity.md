# Single-axis read service-rate sensitivity

2026-09-09 exploratory diagnostic, not calibration. Task-local
`profiles/read-rate-quarter.json` changes only numeric field
`port_read_bytes_per_second`, from14.4GB/s to3.6GB/s. Residual121111ps,
DRAM/AXI/kernel clocks, write and aggregate service budgets, and burst credits
are unchanged. Status is explicitly `diagnostic-only`. Production documentation
profile remains unchanged.

Observer-free `archived-diagnostic-read-rate-quarter` uses the same guarded
archived DUT and repo RAM exception as the control. Its generated manifest
confirms3.6GB/s and121111ps. Both standard-binary output checks and within-run
hash checks pass:

| M=N16 workload | Document control cycles | Quarter read-rate cycles | Delta |
| --- | ---: | ---: | ---: |
| K16 | 7344 | 7344 | 0 |
| K4096 | 11394 | 11469 | +75 |

For comparison, the independent +100ns residual perturbation changed these
cases by+448 and+1348 cycles. In these tested settings, runtime is much more
sensitive to the added read delay than to this large per-port rate reduction.
This is evidence against the nominal per-port read rate ceiling being the
dominant modeled constraint for these cases. It does not prove that real
hardware bandwidth, other aggregate limits, writes or switch contention are
irrelevant. Sensitivities are finite perturbations with overlap/polling effects,
not derivatives or a validated linear fitting model. No acceptance tolerance
or calibrated profile has been selected.

Raw evidence in `build_hbm_reference_document`:
`sensitivity_read_quarter_k{16,4096}_1.log`, corresponding `_simv.log` and
`_before.sha256`. Build log:
`build_hbm_reference/sim/xrtsim_vcs/read_rate_quarter_build.log`.
Build86735 and two-run session75743 are terminal; launch restored.

Configuration regression after diagnostic-status addition: all8 tests pass
from configured `build_hbm_reference/sim/xrtsim_vcs` with proper config sourced;
log `diagnostic_schema_config_regression.log`. An initial attempt from the repo
root failed to locate generated Makefile includes; no code fix was made for
that invocation error. No hardware runs or production model-default changes.
