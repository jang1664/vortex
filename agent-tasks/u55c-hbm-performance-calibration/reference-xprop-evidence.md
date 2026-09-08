# Actual reference Xprop instrumentation

Read-only audit on 2026-09-08 of observer-free
`build_hbm_reference/sim/xrtsim_vcs/archived-document-guarded-mul`.
This is instrumentation evidence, not a proof of complete X detection.

`vcs_elab.log` records the task-local `fma_f32mul_module_xprop.cfg`.
The generated `simv.daidir/.vhdl_xprop_configfile` also names that config and
the two intended vendor exclusions (`xil_fma_lowL`, `xil_f32mul_latency1`).
Its internal numeric fields are not interpreted here as a coverage measure.

The actual SV `xprop.log` contains467 YES and26 NO records (repeated
elaborations included; these are not unique modules or a coverage percentage).
YES records include the AXI guard, both bound floating-point guards, and
repo-selected DP/SP RAM processes. The latter compile through `rtl-library`
symlinks, whose source provenance is checked separately by the compile audit.

The26 NO records comprise five TB and21 DUT records. Reasons include disabled
return/break/continue statements, dynamic types/variables, and non-pure function
calls. DUT examples are job descriptor/dispatcher helpers, GEMM FSM `scbuf_base`
and `cfg_get_u64`, stream DMA queues, DMA alignment, and FP32-to-FP16 rounding.
These are compiler instrumentation limitations, not newly added exclusions.
Therefore “all non-vendor RTL is fully Xprop-instrumented” is **not** supported.
Assertions and boundary guards remain enabled; passing their tests does not
prove unknowns cannot be masked elsewhere in the DUT.

The VHDL log contains both YES and NO records in shared vendor HDL, including
pragma-contained processes and non-local subprogram references. Shared source
locations alone cannot identify which elaborated wrapper instance each record
belongs to. Existing standalone known-input and injected-X guard tests provide
complementary behavioral evidence, not complete hierarchy coverage.

Raw-log SHA256:

- `xprop.log`: `de4e2f74d3a668f7d33544cbe0e93c4104dd1c7870f5863ef5093c9cefb54817`
- `xprop_vhdl.log`: `685ac0601da239c3239b41ecf51961e58e974d2de1751c358e11d02cfa69bfff`

No build flags, RTL, IP or executable changed during this audit. Installed
primitive-library provenance and any stronger hierarchy-specific Xprop claims
remain separate open checks. Do not change archived helpers or turn off DUT
X checks to make this report green.
