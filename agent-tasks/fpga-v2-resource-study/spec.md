# FPGA v2 Fig.5 / Table VI rerun

Status: confirmed by user request on 2026-10-01.

Use fpint-fpga-v2 revision 1e4b367cc, the four explicitly supplied FPGA binary aliases, and GEMM_IMPROVE for matched WKV/WoQ. Reuse existing OOC synthesis, native DSP mapping and verification helpers. No paper edits or production GEMM changes.

## RTL scope
Adapt historical hw/rtl/patch/VX_woq* to current GEMM_IMPROVE. Prefer a small current-RTL-derived Q-COL/standard-load specialization instead of obsolete external-ACC ASIC RTL. Preserve current arithmetic, ACC storage, timing cuts and interfaces. Record exact specialization; verify paired Q-COL behavior, independent numeric oracle and WKV Q-ROW sanity before accepting WoQ results. RTL implementer owns patch WoQ files and new task prepare_test.py/test/; main agent owns run/collect/plot/config/provenance.

## Measurement
16x16 FP-INT from C4 config and actual unmodified C1 TCU geometry (NUM_THREADS16 TCU_DP0 implies128 FP16 MAC/cycle; do not silently retain historical forced64). OOC synth + production RAM patch + opt_design, U55C, nominal100MHz, 2ops/MAC; no routed Fmax/power claims. Fig.5 memory sweep is controlled independently synthesized block costs, not integrated candidates; record exact capacities/ports. Native DSPs and all resource counts, matched WoQ/WKV ACC.

## Artifacts
New agent-tasks/fpga-v2-resource-study: provenance, tests, raw reports, JSON/CSV, Fig.5 PDF/PNG, Table VI LaTeX and reproduction README. Preserve old studies.
