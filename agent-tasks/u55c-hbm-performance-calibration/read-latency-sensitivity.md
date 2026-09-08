# Controlled read-residual sensitivity experiment

2026-09-09. This is diagnostic sensitivity, not a selected calibration.
Task-local `profiles/read-plus100ns.json` changes the documentation profile's
sole numeric field `read_residual_ps` from121111 to221111. Clocks, raw service
budgets, burst credits and Ramulator settings remain identical. Metadata names
and provenance explicitly identify the perturbation. The production document
profile file is unchanged.

The schema now accepts `diagnostic-only` in addition to documented/calibrated
statuses, avoiding mislabelling an invented sensitivity point as board evidence.
Five schema tests pass, including explicit diagnostic acceptance and rejection
of an unknown status. No default profile selection changes. Generator-source
hashes can consequently differ from older builds; numeric profile comparison,
not equal manifests, establishes the controlled setting change.

Isolated observer-free `archived-diagnostic-read-plus100ns` uses the same
archived DUT, repo RAM exception and three guarded vendor-IP exclusions as
the document control. Both standard-binary runs pass output verification and
before/after executable/manifest/program hash checks:

- K16:7792 cycles,6253 instructions.
- K4096:12742 cycles,6649 instructions.

Existing guarded-add document K4096 replay is11394 cycles,6577 instructions;
the perturbation adds1348 cycles. Existing hardware median16749 remains4007
cycles above the perturbed result. This demonstrates positive read-delay
sensitivity but does not establish that a larger arbitrary residual is the
correct model, nor that other parameters are irrelevant. Overlap and polling
make a single-point response unsuitable for linear extrapolation to a fitted
latency. These cases are exploratory, not held-out.

Raw logs: `build_hbm_reference_document/sensitivity_plus100ns_k{16,4096}_1`
with corresponding `_simv.log` and `_before.sha256`; build log
`build_hbm_reference/sim/xrtsim_vcs/read_plus100ns_build.log`.
Build64206 and two-run session67797 are terminal. A fresh guarded-add K16
control replay is tracked separately before reporting its delta.
No hardware run, model-default update or acceptance claim was made.

Fresh K16 guarded-add control completed00:06: PASS at7344 cycles/6253
instructions, matching the older control. K16 delta is448 cycles versus
K4096 delta1348. Raw control stem `sensitivity_control_k16_1`; session94283
terminal, hash checks pass and original clean launch links restored. A single
common residual perturbation affects short and long cases differently; neither
result is a universal startup correction. Repeatability/other-axis checks remain
necessary before fitting, and the user has not selected an acceptance tolerance.
