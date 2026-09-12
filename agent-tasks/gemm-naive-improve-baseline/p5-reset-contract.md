# Naive reset contract

The node now reports `naive active-invocation reset is unsupported` when reset
is sampled while an accepted invocation remains active. The diagnostic is inside
`ifndef SYNTHESIS`; it adds no state, interface or hardware behavior. Initial
unknown state does not trigger it: only a known active value does.

The integration fixture verifies initial reset and a second quiescent reset.
Its expected-failure case presents a valid job at the existing frontend/control
configuration boundary, checks the actual acceptance edge and real job-active
state, then asserts reset. It never forces the active flag or done state. This
checks the node reset boundary; it is not a test of MMIO allocation or supported
cancellation of outstanding memory transactions.

Both MXU16 and MXU32 pass initial/quiescent reset and match the expected active-reset diagnostic. All four cases have completed with stable source hashes.

Fresh VCS cases and expected-diagnostic matching are retained under
p5-verification/reset-contract-iteration1/. Consult summary.json for the terminal
status of each geometry. A generic nonzero return code is insufficient: the
negative test must reach ACTIVE_RESET_JOB_ACCEPTED and fail with the exact node
diagnostic. The fallback testbench error for a missing diagnostic is rejected.

p5-verification/reset-hardware-isolation/result.json compares the measured M256
node source against the diagnostic addition. Synthesis-selected RTL is exactly
equal at MXU16/32 with PERF off/on, apart from permitted source-location output.
No synthesis was run. This comparison bridges the final performance captures to
the diagnostic-only source change; runtime tests verify the added diagnostic.

Occupied isolated-adapter reset requires the complete modeled response domain
to be reset/flushed together. That separate coverage is still under audit; this
change does not authorize adapter-only reset while old responses survive.
