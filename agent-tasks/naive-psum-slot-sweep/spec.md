# Naive PSUM slot saturation experiment

Status: confirmed by user request on 2026-09-11.

## Goal and scope

Measure when increasing naive PSUM response metadata/data capacity stops
reducing cycles. Grow the accumulator tagged read/data slots and physical
response assembly slots together: use the verified 16/16 reference, then
measure 32/32 and 64/64. Add larger sizes only if the trend and reachable
pipeline occupancy justify them. All other pipeline capacities, mandatory
prefetch admission, and the two-entry response transport FIFO stay fixed.

Expose naive-specific compile settings, retaining the default capacity of
16. Preserve improve at RTL level. No synthesis or fine reset testing.

## Measurement

Use fpint_gemm_ffn_hw_naive through ci/run_black.sh xrt-vcs-sim in separately
configured build directories for each capacity. Source the existing
TH16/MXU16 config, append only the two slot defines and the existing latency
observer, and run M4/M256, K=N512, QBLK32, QCOL, WT0, one invocation.
Require PASS, matching source/config provenance, and observer/core cycles.
Use tools/verify_rtl.py pass/failure helpers with wrapper-captured logs.

Report the complete capacity/cycle curve and incremental reductions. Exact
equal cycles across a doubling demonstrate an observed plateau; less than
1 percent improvement is a practical plateau, which must be identified as
such rather than exact saturation. Account for unchanged upstream capacity
limits before claiming a global result. Do not select a new production
default as part of this measurement-only request.

The cycle-only comparison document remains the default16 reference. Put the
sweep cycle table in its own hardware-analysis document; keep validation
details and run logs in this task.
