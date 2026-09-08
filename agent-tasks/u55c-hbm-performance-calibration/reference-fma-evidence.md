# Archived FMA simulation diagnosis

## Guarded configuration and first passing reference smoke

`reference_fma_guard.sv` checks valid/control/tag/mask, required operands of
active lanes, and active result data. It ignores C for non-FMA operations and
masked lanes. The separate bind file attaches it to archived `VX_fpu_fma`
without source edits. Eleven directed VCS cases pass; logs are in
`build_hbm_reference/sim/xrtsim_vcs/fma-boundary-tests/`.

The actual vendor-IP probe with captured inputs passes with the guard and
scoped exclusion. The deliberate X-input probe fails at the boundary guard
before the IP can convert X to zero. Both also pass the external SV X-control
check. Final scope configuration `fma_module_xprop.cfg` excludes only the
`xil_fma_lowL` subtree and retains Xprop on surrounding DUT/guard code.
Probe logs: `fma_module_known.log`, `fma_module_unknown.log` in the RAM stage.

The temporary Makefile selects this guarded configuration only through
`REFERENCE_FMA_GUARD=1`; its default remains global tmerge. Fresh stage
`archived-document-guarded-fma` includes both repo RAM definitions, archived
non-RAM DUT/headers, current backend, and the two guard files (no diagnostic
observers). Compile audit: 2 approved RAM, 217 archive, 7 harness, 0 unexpected.
Report: `build_hbm_reference/sim/xrtsim_vcs/guarded_fma_compile_audit.json`.

Two archived vecadd -n64 executions **passed**, each reporting 16692 instructions
and 16064 cycles. Both shut down normally. Raw host logs:
`build_hbm_reference_document/archived_guarded_fma_vecadd.log` and
`archived_guarded_fma_vecadd_repeat.log`. Executable/manifest/bridge/program
hashes remained unchanged (`guarded_vecadd_before.sha256`). This proves this
smoke and its repeatability, not all FPU operations or hardware fidelity.
Other vendor IP scopes retain their original Xprop setting and need their own
evidence if a future workload exposes a similar problem.

## Scoped-Xprop experiment (2026-09-08 22:00)

Installed VCS W-2024.09-SP1 documentation under
`doc/UserGuide/smartsearch/doc/html/vcs_user_guide/using_x_propagation/`
defines `tree` selectors as module names and `instance` selectors as hierarchy
paths. The first experiment incorrectly used a hierarchy path in a `tree`
rule; it did not fix known-input arithmetic and is not successful evidence.

Corrected `fma_probe_xprop.cfg` enables tmerge on the testbench hierarchy and
excludes only instance `tb_reference_fma.dut`. In the corrected experiment:

- Captured known operands produce 3fc2f07e and REFERENCE_FMA_PASS.
- A separate SV conditional driven by X produces X (REFERENCE_X_CONTROL_PASS),
  demonstrating that the surrounding SV X-propagation remains active.
- Intentional all-X operand produces 00000000 inside the excluded vendor IP;
  the explicit unknown-input test fails. This exclusion alone is **not accepted**.

Logs: `fma_probe_scoped_v2_known.log` and `fma_probe_scoped_v2_unknown.log`
in the reference stage. Before any application use, add and test boundary
checks for active operations that detect unknown required operands/control
and unknown active results. Respect lane masks and unused operands; do not
reject legal inactive-lane values or silently coerce active unknowns to zero.
No production/reference application Xprop setting has been changed yet.

Known DSP-FPU operands reach the FMA, but its result is X in the full reference
run. A standalone `tb_reference_fma.sv` uses the same archived VHDL wrapper,
compiled libraries and work/xil_defaultlib binding without the DUT or HBM.

| Test | X-propagation | Outcome |
| --- | --- | --- |
| 1*1+1, continuous enable (initial probe) | none | 40000000, PASS |
| 1*1+1, first four enabled cycles only (initial probe) | none | 40000000, PASS |
| 1*1+1, idle input zero (final probe) | tmerge | X, Fatal |
| Captured operands, continuous enable | tmerge | X, Fatal |
| Captured operands, four-cycle enable | tmerge | X, Fatal |
| Captured operands, continuous enable (same final TB) | none | 3fc2f07e, PASS |

Captured operands: a=3f64f23c, b=3f800000, c=3f20eebf. Expected single-precision
result is 3fc2f07e. The model reports C_LATENCY=4, C_HAS_ACLKEN=1,
C_HAS_ARESETN=0. Inputs change 1ns after a falling edge, avoiding stimulus races
with the rising sampling edge; inactive data is driven to zero in the final TB.

Logs under `build_hbm_reference/sim/xrtsim_vcs/archived-document-repo-rams`:
`fma_probe_continuous.log`, `fma_probe_gated.log`,
`fma_probe_simple_xprop.log`, `fma_probe_captured_continuous.log`,
`fma_probe_captured_gated.log`, `fma_probe_captured_plain.log`.
Compiler logs and separate `simv_fma_probe` / `simv_fma_probe_plain` executables
are retained. VCS can return exit zero after `$fatal`; PASS markers and fatal
absence must be checked explicitly.

This demonstrates an X-propagation interaction in this standalone setup. It
does not yet identify the internal source or authorize dropping all DUT X
checks. Next investigate a narrow configuration boundary and validate it with
both known-input arithmetic and intentional-X controls before applying it to
the historical reference build. No FPU RTL or IP source has been changed.
